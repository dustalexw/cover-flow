import AVFoundation

struct AudioSource: Equatable {
    var index: Int
    let trackID: UUID
    let url: URL
}

/// One continuous PCM stream, with eight seconds of bounded lookahead. Completion
/// callbacks update the UI; they never initiate the next track's audio.
@MainActor
final class GaplessAudioPlayer {
    let visualizerAudio = VisualizerAudioBuffer()
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var pump: Task<Void, Never>?
    private var generation = UUID()
    private var segments: [Segment] = []
    private var scheduledFrames: AVAudioFramePosition = 0
    private var pausedFrames: AVAudioFramePosition = 0
    private var finishedScheduling = false
    private var pendingFailure: (AudioSource, Error)?
    private var wantsPlayback = false
    private var reportedSegment: UUID?
    private var lastReportedTime: Double?
    private var ended = false
    private var decodingSource: AudioSource?
    private var configurationObserver: NSObjectProtocol?

    private struct Segment {
        let id = UUID()
        var source: AudioSource
        let startFrame: AVAudioFramePosition
        var endFrame: AVAudioFramePosition
        let offset: Double
        let duration: Double
    }

    var nextSource: ((AudioSource) -> AudioSource?)?
    var onTrackChanged: ((AudioSource, Double, Bool) -> Void)?
    var onStateChanged: (() -> Void)?
    var onTimeChanged: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    var onFailure: ((AudioSource, Error) -> Void)?
    private(set) var source: AudioSource?
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    var volume: Float = 0.8 { didSet { updateVolume() } }
    var isMuted = false { didSet { updateVolume() } }

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: PCMDecoder.outputFormat)
        let audio = visualizerAudio
        node.installTap(onBus: 0, bufferSize: 512, format: PCMDecoder.outputFormat) { buffer, _ in
            guard let channels = buffer.floatChannelData, buffer.format.channelCount >= 2 else { return }
            audio.append(left: channels[0], right: channels[1], frames: Int(buffer.frameLength))
        }
        updateVolume()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let source = self.source else { return }
                self.load(source, autoplay: self.wantsPlayback, at: self.currentTime)
            }
        }
    }

    deinit {
        pump?.cancel()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    private func updateVolume() { node.volume = isMuted ? 0 : volume }

    func load(_ source: AudioSource, autoplay: Bool, at start: Double = 0) {
        reset()
        self.source = source
        currentTime = start
        wantsPlayback = autoplay
        isPlaying = autoplay
        isBuffering = autoplay
        onStateChanged?()
        let token = generation
        pump = Task { [weak self] in
            guard let self else { return }
            var tail = source
            var offset = start
            var decoder: PCMDecoder?
            while !Task.isCancelled && self.generation == token {
                self.poll()
                guard self.generation == token else { return }
                let rendered = self.renderedFrames
                if !self.finishedScheduling && self.scheduledFrames - rendered < 8 * AVAudioFramePosition(PCMDecoder.sampleRate) {
                    do {
                        if decoder == nil {
                            self.decodingSource = tail
                            let opened = try await Task.detached { try PCMDecoder(url: tail.url, start: offset) }.value
                            guard self.generation == token else { return }
                            decoder = opened
                            self.segments.append(Segment(source: tail, startFrame: self.scheduledFrames,
                                                         endFrame: self.scheduledFrames, offset: offset, duration: opened.duration))
                        }
                        let chunk = try await decoder!.read()
                        guard self.generation == token else { return }
                        if let chunk {
                            self.scheduledFrames += AVAudioFramePosition(chunk.buffer.frameLength)
                            self.segments[self.segments.count - 1].endFrame = self.scheduledFrames
                            let endFrame = self.scheduledFrames
                            self.node.scheduleBuffer(chunk.buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                                Task { @MainActor in
                                    guard let self, self.generation == token else { return }
                                    self.poll(completedThrough: endFrame)
                                }
                            }
                        }
                        if chunk == nil || chunk!.isLast {
                            if let next = self.nextSource?(tail) {
                                tail = next
                                offset = 0
                                decoder = nil
                            } else {
                                self.finishedScheduling = true
                            }
                        }
                        if self.wantsPlayback && !self.node.isPlaying && self.readyToStart {
                            try self.startNode()
                            self.isBuffering = false
                            self.onStateChanged?()
                        }
                        continue
                    } catch {
                        guard self.generation == token else { return }
                        self.pendingFailure = (tail, error)
                        self.finishedScheduling = true
                        // Empty failed segments must not mask the preceding track.
                        self.segments.removeAll { $0.startFrame == $0.endFrame }
                        if self.wantsPlayback && self.scheduledFrames > 0 && !self.node.isPlaying {
                            do { try self.startNode(); self.isBuffering = false; self.onStateChanged?() }
                            catch { self.pendingFailure = (tail, error); self.scheduledFrames = self.renderedFrames }
                        }
                        self.poll()
                    }
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private var renderedFrames: AVAudioFramePosition {
        guard node.isPlaying else { return pausedFrames }
        guard let time = node.lastRenderTime, let position = node.playerTime(forNodeTime: time) else { return 0 }
        return max(0, position.sampleTime)
    }

    private func poll(completedThrough: AVAudioFramePosition = 0) {
        let frame = max(renderedFrames, wantsPlayback ? completedThrough : 0)
        if let segment = segments.last(where: { $0.startFrame <= frame && $0.endFrame > $0.startFrame }) {
            source = segment.source
            currentTime = min(segment.duration, segment.offset + Double(min(frame, segment.endFrame) - segment.startFrame) / PCMDecoder.sampleRate)
            if reportedSegment != segment.id {
                let transitioned = reportedSegment != nil
                reportedSegment = segment.id
                onTrackChanged?(segment.source, segment.duration, transitioned)
            }
            if lastReportedTime == nil || abs(currentTime - lastReportedTime!) >= 0.25 {
                lastReportedTime = currentTime
                onTimeChanged?(currentTime)
            }
            // Retain only the active track and future tracks, even on Repeat One.
            segments.removeAll { $0.endFrame <= segment.startFrame && $0.id != segment.id }
        }
        if finishedScheduling && frame >= scheduledFrames && !ended {
            ended = true
            let failure = pendingFailure
            pause()
            if let failure { onFailure?(failure.0, failure.1) } else { onEnd?() }
        }
    }

    private var readyToStart: Bool {
        scheduledFrames >= 2 * AVAudioFramePosition(PCMDecoder.sampleRate) || (finishedScheduling && scheduledFrames > 0)
    }

    private func startNode() throws {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        if !engine.isRunning { try engine.start() }
        node.play()
    }

    func play() {
        wantsPlayback = true
        isPlaying = true
        do {
            if readyToStart { try startNode(); isBuffering = false }
            else { isBuffering = true }
        } catch {
            pause()
            if let source { onFailure?(source, error) }
        }
        onStateChanged?()
    }

    func pause() {
        pausedFrames = renderedFrames
        node.pause()
        visualizerAudio.clear()
        wantsPlayback = false
        isPlaying = false
        isBuffering = false
        onStateChanged?()
    }

    func seek(to seconds: Double) {
        guard let source else { return }
        load(source, autoplay: wantsPlayback, at: seconds)
    }

    func synchronize() { poll() }

    /// Queue edits must invalidate every prepared successor, including a decode
    /// currently in flight. An unchanged prepared sequence keeps playing.
    func refreshUpcoming(current: AudioSource) {
        guard source?.trackID == current.trackID else { return }
        if source == current, let active = segments.firstIndex(where: { $0.id == reportedSegment }) {
            var previous = current
            var matches = true
            for segment in segments.dropFirst(active + 1) {
                if segment.source != nextSource?(previous) { matches = false; break }
                previous = segment.source
            }
            if let decodingSource, decodingSource != previous && decodingSource != nextSource?(previous) { matches = false }
            if finishedScheduling && nextSource?(previous) != nil { matches = false }
            if matches { return }
        }
        load(current, autoplay: wantsPlayback, at: currentTime)
    }

    func stop() {
        reset()
        source = nil
        currentTime = 0
        wantsPlayback = false
        isPlaying = false
        isBuffering = false
        onStateChanged?()
    }

    private func reset() {
        visualizerAudio.clear()
        generation = UUID()
        pump?.cancel()
        pump = nil
        node.stop()
        segments.removeAll()
        scheduledFrames = 0
        pausedFrames = 0
        finishedScheduling = false
        pendingFailure = nil
        reportedSegment = nil
        lastReportedTime = nil
        decodingSource = nil
        ended = false
    }
}
