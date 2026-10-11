import AVFoundation
import AppKit
import Combine
import MediaPlayer

private struct PlaybackSnapshot: Codable {
    var queue: [UUID]
    var currentIndex: Int?
    var position: Double
    var shuffle: Bool
    var repeatMode: RepeatMode
    var volume: Float
    var muted: Bool
    var unshuffled: [UUID]?
}

/// The single source of truth for playback. Every view observes this, so state stays in sync.
@MainActor
final class PlayerEngine: ObservableObject {
    @Published private(set) var queue: [UUID] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isMuted = false
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published var errorMessage: String?
    @Published var volume: Float = 0.8 {
        didSet { player.volume = volume; scheduleSave() }
    }

    private let player = GaplessAudioPlayer()
    var visualizerAudio: VisualizerAudioBuffer { player.visualizerAudio }
    private unowned let library: LibraryStore
    private let scrobbler: LastFmScrobbler
    private var unshuffled: [UUID]?
    private var consecutiveFailures = 0
    private var pendingSave: DispatchWorkItem?
    private var lastPositionSave = Date.distantPast
    private var failureSkip: DispatchWorkItem?
    private var playbackRequested = false

    init(library: LibraryStore, scrobbler: LastFmScrobbler) {
        self.library = library
        self.scrobbler = scrobbler
        player.volume = volume
        player.nextSource = { [weak self] source in
            guard let self, let next = PlaybackOrder.successor(after: source.index, count: self.queue.count,
                                                              repeatMode: self.repeatMode) else { return nil }
            return self.audioSource(at: next)
        }
        player.onStateChanged = { [weak self] in
            guard let self else { return }
            self.isPlaying = self.player.isPlaying
            self.isBuffering = self.player.isBuffering
            self.observeScrobbling()
            self.updateNowPlayingInfo()
        }
        player.onTimeChanged = { [weak self] time in self?.tick(time) }
        player.onTrackChanged = { [weak self] source, duration, transitioned in
            guard let self, self.queue[safe: source.index] == source.trackID else { return }
            if transitioned {
                self.scrobbler.observe(position: self.duration, duration: self.duration, playing: false)
                self.scrobbler.newPlayback(track: self.library.track(source.trackID), duration: duration, position: self.player.currentTime)
            }
            self.currentIndex = source.index
            self.duration = duration
            self.currentTime = self.player.currentTime
            self.consecutiveFailures = 0
            self.observeScrobbling()
            if transitioned && self.isPlaying { self.announceCurrentTrack() }
            self.updateNowPlayingInfo()
            self.scheduleSave()
        }
        player.onEnd = { [weak self] in
            guard let self else { return }
            self.loadCurrent(autoplay: false)
            Announcer.announce("End of queue")
        }
        player.onFailure = { [weak self] source, error in
            guard let self, let track = self.library.track(source.trackID) else { return }
            self.player.stop()
            self.currentIndex = source.index
            self.currentTime = 0
            self.duration = track.duration
            self.handleFailure(track, reason: error.localizedDescription, wantedToPlay: self.playbackRequested)
        }
        library.onTracksRemoved = { [weak self] ids in
            MainActor.assumeIsolated { self?.purge(ids) }
        }
        configureRemoteCommands()
    }

    // MARK: Derived state

    var currentTrackID: UUID? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }
    var currentTrack: Track? { library.track(currentTrackID) }
    var currentAlbumID: UUID? { currentTrackID.flatMap { library.albumID(forTrack: $0) } }
    var currentAlbum: Album? { library.album(currentAlbumID) }
    var hasTrack: Bool { currentTrackID != nil }
    var remaining: Double { max(0, duration - currentTime) }

    struct QueueEntry: Identifiable, Hashable {
        let id: Int        // absolute index in the queue
        let trackID: UUID
    }

    var upNext: [QueueEntry] {
        let start = (currentIndex ?? -1) + 1
        guard start < queue.count else { return [] }
        return (start..<queue.count).map { QueueEntry(id: $0, trackID: queue[$0]) }
    }

    // MARK: Starting playback

    func play(albumID: UUID, startAt trackID: UUID? = nil, shuffled: Bool? = nil) {
        guard let album = library.album(albumID), !album.trackIDs.isEmpty else { return }
        if let shuffled { shuffle = shuffled }
        let start = trackID.flatMap { album.trackIDs.firstIndex(of: $0) } ?? 0
        setQueue(album.trackIDs, startIndex: start, autoplay: true)
    }

    func setQueue(_ ids: [UUID], startIndex: Int, autoplay: Bool, shuffled: Bool? = nil) {
        guard !ids.isEmpty else { return }
        if let shuffled { shuffle = shuffled }
        var q = ids
        var idx = startIndex.clamped(0, ids.count - 1)
        if shuffle {
            unshuffled = q
            let first = q.remove(at: idx)
            q.shuffle()
            q.insert(first, at: 0)
            idx = 0
        } else {
            unshuffled = nil
        }
        queue = q
        currentIndex = idx
        consecutiveFailures = 0
        errorMessage = nil
        loadCurrent(autoplay: autoplay)
    }

    func togglePlayPause() {
        player.synchronize()
        guard hasTrack else { return }
        if player.source == nil {
            loadCurrent(autoplay: true, at: currentTime)
            return
        }
        if isPlaying {
            pause()
        } else {
            playbackRequested = true
            if duration > 0 && currentTime >= duration - 0.25 { seek(to: 0) }
            player.play()
        }
        scheduleSave()
    }

    func pause() {
        playbackRequested = false
        failureSkip?.cancel()
        player.pause()
        scheduleSave()
    }

    func next() { advance(automatic: false) }

    func previous() {
        player.synchronize()
        guard let idx = currentIndex else { return }
        if currentTime > 3 {
            seek(to: 0)
        } else if idx > 0 {
            currentIndex = idx - 1
            loadCurrent(autoplay: true)
        } else if repeatMode == .all, !queue.isEmpty {
            currentIndex = queue.count - 1
            loadCurrent(autoplay: true)
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: Double) {
        player.synchronize()
        guard hasTrack else { return }
        let target = seconds.clamped(0, max(duration, 0))
        observeScrobbling()
        scrobbler.seek(to: target)
        currentTime = target
        player.seek(to: target)
        updateNowPlayingInfo()
        scheduleSave()
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
        scheduleSave()
    }

    func nudgeVolume(_ delta: Float) {
        volume = (volume + delta).clamped(0, 1)
        if isMuted && delta > 0 { toggleMute() }
    }

    func toggleShuffle() {
        player.synchronize()
        shuffle.toggle()
        guard let idx = currentIndex, queue.indices.contains(idx) else { return }
        let current = queue[idx]
        if shuffle {
            unshuffled = queue
            var rest = Array(queue[(idx + 1)...])
            rest.shuffle()
            queue = Array(queue[...idx]) + rest
        } else if let original = unshuffled, let newIdx = original.firstIndex(of: current) {
            queue = original
            currentIndex = newIdx
            unshuffled = nil
        } else {
            unshuffled = nil
        }
        Announcer.announce(shuffle ? "Shuffle on" : "Shuffle off")
        refreshUpcoming()
        scheduleSave()
    }

    func cycleRepeat() {
        player.synchronize()
        repeatMode = repeatMode.next
        Announcer.announce(repeatMode.label)
        refreshUpcoming()
        scheduleSave()
    }

    // MARK: Queue editing

    func playNext(_ ids: [UUID]) {
        player.synchronize()
        guard !ids.isEmpty else { return }
        if queue.isEmpty || currentIndex == nil {
            setQueue(ids, startIndex: 0, autoplay: false)
            return
        }
        let at = (currentIndex ?? -1) + 1
        queue.insert(contentsOf: ids, at: at)
        unshuffled = nil
        refreshUpcoming()
        scheduleSave()
    }

    func addToQueue(_ ids: [UUID]) {
        player.synchronize()
        guard !ids.isEmpty else { return }
        if queue.isEmpty || currentIndex == nil {
            setQueue(ids, startIndex: 0, autoplay: false)
            return
        }
        queue.append(contentsOf: ids)
        unshuffled = nil
        refreshUpcoming()
        scheduleSave()
    }

    func moveUpNext(from offsets: IndexSet, to destination: Int) {
        player.synchronize()
        let base = (currentIndex ?? -1) + 1
        var upcoming = Array(queue[base...])
        upcoming.move(fromOffsets: offsets, toOffset: destination)
        queue = Array(queue[..<base]) + upcoming
        unshuffled = nil
        refreshUpcoming()
        scheduleSave()
    }

    enum QueueMove { case top, up, down }

    func move(absoluteIndex i: Int, _ move: QueueMove) {
        player.synchronize()
        let base = (currentIndex ?? -1) + 1
        guard i >= base, queue.indices.contains(i) else { return }
        let target: Int
        switch move {
        case .top: target = base
        case .up: target = max(base, i - 1)
        case .down: target = min(queue.count - 1, i + 1)
        }
        guard target != i else { return }
        let id = queue.remove(at: i)
        queue.insert(id, at: target)
        unshuffled = nil
        refreshUpcoming()
        scheduleSave()
    }

    func removeFromQueue(absoluteIndex i: Int) {
        player.synchronize()
        guard queue.indices.contains(i) else { return }
        if i == currentIndex {
            queue.remove(at: i)
            if queue.isEmpty { stop() } else {
                currentIndex = min(i, queue.count - 1)
                loadCurrent(autoplay: isPlaying)
            }
        } else {
            queue.remove(at: i)
            if let c = currentIndex, i < c { currentIndex = c - 1 }
        }
        unshuffled = nil
        refreshUpcoming()
        scheduleSave()
    }

    func clearUpNext() {
        player.synchronize()
        guard let idx = currentIndex else { queue = []; return }
        queue = Array(queue[...idx])
        unshuffled = nil
        refreshUpcoming()
        scheduleSave()
    }

    func jump(toAbsolute i: Int) {
        guard queue.indices.contains(i) else { return }
        currentIndex = i
        consecutiveFailures = 0
        loadCurrent(autoplay: true)
    }

    func stop() {
        player.pause()
        playbackRequested = false
        failureSkip?.cancel()
        player.stop()
        scrobbler.newPlayback(track: nil, duration: 0, position: 0)
        queue = []
        currentIndex = nil
        currentTime = 0
        duration = 0
        updateNowPlayingInfo()
        scheduleSave()
    }

    private func purge(_ ids: Set<UUID>) {
        player.synchronize()
        guard !queue.isEmpty else { return }
        let currentID = currentTrackID
        let currentRemoved = currentID.map { ids.contains($0) } ?? false
        let oldIdx = currentIndex ?? 0
        let removedBefore = queue[..<min(oldIdx, queue.count)].filter { ids.contains($0) }.count
        queue.removeAll { ids.contains($0) }
        unshuffled = unshuffled?.filter { !ids.contains($0) }
        if queue.isEmpty { stop(); return }
        if currentRemoved {
            currentIndex = min(oldIdx - removedBefore, queue.count - 1)
            loadCurrent(autoplay: false)
        } else if let currentID {
            currentIndex = queue.firstIndex(of: currentID)
        }
        refreshUpcoming()
        scheduleSave()
    }

    // MARK: Internals

    private func audioSource(at index: Int) -> AudioSource? {
        guard let id = queue[safe: index], let track = library.track(id) else { return nil }
        return AudioSource(index: index, trackID: id, url: track.fileURL)
    }

    private func refreshUpcoming() {
        guard let index = currentIndex, let source = audioSource(at: index) else { return }
        player.refreshUpcoming(current: source)
    }

    private func advance(automatic: Bool) {
        player.synchronize()
        guard let idx = currentIndex,
              let next = PlaybackOrder.successor(after: idx, count: queue.count,
                                                  repeatMode: repeatMode, automatic: automatic) else { return }
        currentIndex = next
        loadCurrent(autoplay: true)
    }

    private func announceCurrentTrack() {
        guard let trackID = currentTrackID, let track = currentTrack else { return }
        library.markPlayed(trackID: trackID)
        Announcer.announce("Now playing \(track.title) by \(track.artist)")
    }

    private func loadCurrent(autoplay: Bool, at start: Double = 0) {
        failureSkip?.cancel()
        playbackRequested = autoplay
        guard let index = currentIndex, let source = audioSource(at: index), let track = currentTrack else {
            player.stop()
            currentTime = 0
            duration = 0
            updateNowPlayingInfo()
            return
        }
        observeScrobbling()
        scrobbler.newPlayback(track: track, duration: track.duration, position: start)
        duration = track.duration
        currentTime = start
        player.load(source, autoplay: autoplay, at: start)
        if autoplay { announceCurrentTrack() }
        updateNowPlayingInfo()
        scheduleSave()
    }

    private func handleFailure(_ track: Track, reason: String, wantedToPlay: Bool) {
        consecutiveFailures += 1
        errorMessage = "Couldn’t play “\(track.title)”. \(reason)"
        Announcer.announce("Couldn’t play \(track.title)")
        player.pause()
        let canSkip = wantedToPlay && consecutiveFailures < min(queue.count, 6)
            && ((currentIndex ?? 0) + 1 < queue.count || repeatMode == .all)
        if canSkip {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.advance(automatic: false) }
            }
            failureSkip = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    private func tick(_ time: Double) {
        guard player.source != nil else { return }
        if time.isFinite { currentTime = time }
        observeScrobbling()
        if isPlaying, Date().timeIntervalSince(lastPositionSave) > 10 {
            lastPositionSave = Date()
            saveNow()
        }
    }

    private func observeScrobbling() {
        scrobbler.observe(position: player.currentTime, duration: duration, playing: player.isPlaying && !player.isBuffering)
    }

    // MARK: Persistence

    func restore() {
        guard let data = try? Data(contentsOf: AppPaths.playback),
              let snap = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data) else { return }
        shuffle = snap.shuffle
        repeatMode = snap.repeatMode
        volume = snap.volume
        isMuted = snap.muted
        player.isMuted = snap.muted
        let valid = snap.queue.filter { library.track($0) != nil }
        guard !valid.isEmpty else { return }
        var idx = snap.currentIndex.flatMap { snap.queue[safe: $0] }.flatMap { valid.firstIndex(of: $0) } ?? 0
        idx = idx.clamped(0, valid.count - 1)
        queue = valid
        unshuffled = snap.unshuffled?.filter { library.track($0) != nil }
        currentIndex = idx
        loadCurrent(autoplay: false, at: snap.position)
    }

    func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        let snap = PlaybackSnapshot(queue: queue, currentIndex: currentIndex, position: currentTime, shuffle: shuffle,
                                    repeatMode: repeatMode, volume: volume, muted: isMuted, unshuffled: unshuffled)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: AppPaths.playback, options: .atomic)
        }
    }

    // MARK: System Now Playing + media keys

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            onMain { if self?.isPlaying == false { self?.togglePlayPause() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            onMain { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            onMain { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            onMain { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            onMain { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            onMain { self?.seek(to: t) }
            return .success
        }
    }

    private var nowPlayingArtworkKey: String?
    private var nowPlayingArtwork: MPMediaItemArtwork?

    private func updateNowPlayingInfo() {
        let info = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: currentAlbum?.title ?? track.albumTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let album = currentAlbum, album.hasArtwork {
            if nowPlayingArtworkKey != album.artworkKey {
                nowPlayingArtworkKey = album.artworkKey
                nowPlayingArtwork = nil
                let store = library.artwork
                Task { [weak self] in
                    guard let image = await store.thumbnail(album, pixels: 600) else { return }
                    await MainActor.run {
                        guard let self, self.nowPlayingArtworkKey == album.artworkKey else { return }
                        self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        self.updateNowPlayingInfo()
                    }
                }
            }
            if let art = nowPlayingArtwork { dict[MPMediaItemPropertyArtwork] = art }
        }
        info.nowPlayingInfo = dict
        info.playbackState = isPlaying ? .playing : .paused
    }
}

/// Runs work on the main actor regardless of which thread a system callback arrives on.
private func onMain(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { work() }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
}
