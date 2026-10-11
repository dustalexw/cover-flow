import SwiftUI
import AppKit

/// Holds the continuous browsing position. Fractional values are between two albums.
@MainActor
final class CoverFlowController: ObservableObject {
    @Published var position: Double = 0
    var count = 0
    var reduceMotion = false
    private var dragStart: Double?
    private var snapWork: DispatchWorkItem?
    private var wheelAccumulator: CGFloat = 0
    private(set) var target: Int = 0

    var index: Int { count == 0 ? 0 : Int(position.rounded()).clamped(0, count - 1) }

    private var spring: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.42, dampingFraction: 0.86)
    }

    func go(to i: Int, animated: Bool = true) {
        guard count > 0 else { return }
        let t = i.clamped(0, count - 1)
        target = t
        if animated {
            withAnimation(spring) { position = Double(t) }
        } else {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { position = Double(t) }
        }
    }

    func step(_ delta: Int) {
        // Base rapid key presses on the destination, not the in-flight position.
        let base = abs(Double(target) - position) < 1.5 ? target : index
        go(to: base + delta)
    }

    private func rubberBand(_ p: Double) -> Double {
        let maxP = Double(max(count - 1, 0))
        if p < 0 { return -pow(-p, 0.7) * 0.35 }
        if p > maxP { return maxP + pow(p - maxP, 0.7) * 0.35 }
        return p
    }

    private func setLive(_ p: Double) {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { position = rubberBand(p) }
    }

    func dragChanged(_ translation: CGFloat, unit: CGFloat) {
        snapWork?.cancel()
        if dragStart == nil { dragStart = position }
        setLive((dragStart ?? 0) - Double(translation / unit))
    }

    func dragEnded(predicted: CGFloat, unit: CGFloat) {
        let start = dragStart ?? position
        dragStart = nil
        // Limit how far a fling can travel so it stays controllable.
        let travel = Double(predicted / unit).clamped(-12, 12)
        go(to: Int((start - travel).rounded()))
    }

    func scroll(_ event: NSEvent, unit: CGFloat) {
        guard count > 0 else { return }
        if event.hasPreciseScrollingDeltas {
            // Trackpad / Magic Mouse: glide continuously, then settle.
            let dx = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            setLive(position - Double(dx / unit))
            snapWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { guard let self else { return }; self.go(to: self.index) }
            }
            snapWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: work)
        } else {
            // Mouse wheel: one album per notch.
            let d = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            wheelAccumulator += d
            if abs(wheelAccumulator) >= 0.9 {
                step(wheelAccumulator > 0 ? -1 : 1)
                wheelAccumulator = 0
            }
        }
    }
}

private enum CoverFlowLayout {
    static let reflectionFraction: CGFloat = 0.14
    static let reflectionSpacing: CGFloat = 3
    static let verticalPadding: CGFloat = 8
    static let captionSpacing: CGFloat = 4
}

struct CoverFlowView: View {
    let albums: [Album]
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var state: AppState
    @StateObject private var flow = CoverFlowController()
    @FocusState private var focused: Bool
    @State private var selectionDragStart: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var current: Album? { albums[safe: flow.index] }

    var body: some View {
        GeometryReader { geo in
            let compactCaption = geo.size.width >= 900
            let captionHeight: CGFloat = compactCaption ? 100 : 148
            let scrubberHeight: CGFloat = albums.count > 6 ? 20 : 0
            let size = coverSize(for: geo.size, captionHeight: captionHeight, scrubberHeight: scrubberHeight)
            let unit = size * 0.3
            VStack(spacing: 0) {
                artworkStage(size: size, unit: unit)

                AlbumCaption(album: current, compact: compactCaption, onPlay: playCurrent, onTracks: openCurrent)
                    .frame(height: captionHeight)
                    .padding(.top, CoverFlowLayout.captionSpacing)

                if albums.count > 6 {
                    CollectionScrubber(flow: flow, count: albums.count)
                        .frame(maxWidth: min(560, geo.size.width - 80))
                        .frame(height: scrubberHeight)
                }
            }
            .padding(.vertical, CoverFlowLayout.verticalPadding)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { event in navigate(-1, extend: event.modifiers.contains(.shift)); return .handled }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { event in navigate(1, extend: event.modifiers.contains(.shift)); return .handled }
        .onKeyPress(.home) { flow.go(to: 0); return .handled }
        .onKeyPress(.end) { flow.go(to: albums.count - 1); return .handled }
        .onKeyPress(.pageUp) { flow.step(-5); return .handled }
        .onKeyPress(.pageDown) { flow.step(5); return .handled }
        .onKeyPress(.escape) { state.selection.clear(); return .handled }
        .onKeyPress(phases: .down) { event in
            guard event.modifiers.contains(.command), event.characters.lowercased() == "a" else { return .ignored }
            state.selection.selectAll(albums.map(\.id)); return .handled
        }
        .onKeyPress(.return) { openCurrent(); return .handled }
        .onKeyPress(.space) { playCurrent(); return .handled }
        .onAppear {
            flow.reduceMotion = reduceMotion
            flow.count = albums.count
            let start = state.browsedAlbumID.flatMap { id in albums.firstIndex { $0.id == id } } ?? 0
            flow.go(to: start, animated: false)
            focused = true
        }
        .onChange(of: albums.map(\.id)) {
            flow.count = albums.count
            let i = state.browsedAlbumID.flatMap { id in albums.firstIndex { $0.id == id } } ?? 0
            flow.go(to: i, animated: false)
        }
        .onChange(of: flow.index) {
            if let id = albums[safe: flow.index]?.id, id != state.browsedAlbumID { state.browsedAlbumID = id }
        }
        .onChange(of: state.revealRequest) {
            guard let req = state.revealRequest, let i = albums.firstIndex(where: { $0.id == req.id }) else { return }
            flow.go(to: i)
        }
        .onChange(of: reduceMotion) { flow.reduceMotion = reduceMotion }
    }

    private var browseDescription: String {
        guard let current else { return "Empty" }
        return "\(current.title) by \(current.artist), album \(flow.index + 1) of \(albums.count)"
    }

    private func artworkStage(size: CGFloat, unit: CGFloat) -> some View {
        CoverFlowStage(position: flow.position, albums: albums, coverSize: size,
                       playingAlbumID: player.currentAlbumID, isPlaying: player.isPlaying,
                       reduceMotion: reduceMotion) { index in
            handleTap(index)
        }
        .frame(maxWidth: .infinity)
        .frame(height: size * (1 + CoverFlowLayout.reflectionFraction) + CoverFlowLayout.reflectionSpacing)
        .contentShape(Rectangle())
        .gesture(browseDrag(unit: unit))
        .background(ScrollWheelCatcher { flow.scroll($0, unit: unit) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cover Flow")
        .accessibilityValue(browseDescription)
        .accessibilityHint("Use left and right arrows to browse. Return shows tracks, Space plays.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: flow.step(1)
            case .decrement: flow.step(-1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Play") { playCurrent() }
        .accessibilityAction(named: "Show Tracks") { openCurrent() }
    }

    private func browseDrag(unit: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if selectionDragStart != nil || (NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) {
                    if selectionDragStart == nil {
                        selectionDragStart = flow.index
                        if state.selection.anchor == nil, let id = current?.id { state.selection.select(id, ordered: albums.map(\.id)) }
                    }
                    let travel = Int((value.translation.width / unit).rounded())
                    let index = ((selectionDragStart ?? 0) - travel).clamped(0, albums.count - 1)
                    if let id = albums[safe: index]?.id { state.selection.select(id, ordered: albums.map(\.id), extend: true) }
                    flow.go(to: index, animated: false)
                } else { flow.dragChanged(value.translation.width, unit: unit) }
            }
            .onEnded { value in
                if selectionDragStart != nil { selectionDragStart = nil }
                else { flow.dragEnded(predicted: value.predictedEndTranslation.width, unit: unit) }
            }
    }

    private func coverSize(for size: CGSize, captionHeight: CGFloat, scrubberHeight: CGFloat) -> CGFloat {
        let reservedHeight = captionHeight + scrubberHeight + CoverFlowLayout.captionSpacing
            + CoverFlowLayout.verticalPadding * 2 + CoverFlowLayout.reflectionSpacing
        let byHeight = (size.height - reservedHeight) / (1 + CoverFlowLayout.reflectionFraction)
        return max(1, min(byHeight, size.width * 0.58))
    }

    private func navigate(_ delta: Int, extend: Bool) {
        if extend, state.selection.anchor == nil, let album = current { state.selection.select(album.id, ordered: albums.map(\.id)) }
        flow.step(delta)
        if extend, let album = albums[safe: flow.target] {
            state.selection.select(album.id, ordered: albums.map(\.id), extend: true)
        }
    }

    private func handleTap(_ index: Int) {
        guard let album = albums[safe: index] else { return }
        focused = true
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift), state.selection.anchor == nil, let current {
            state.selection.select(current.id, ordered: albums.map(\.id))
        }
        state.selection.select(album.id, ordered: albums.map(\.id), extend: flags.contains(.shift), toggle: flags.contains(.command))
        flow.go(to: index)
        if (NSApp.currentEvent?.clickCount ?? 0) >= 2 && !flags.contains(.shift) && !flags.contains(.command) {
            state.detailAlbum = IDRef(id: album.id)
        }
    }

    private func playCurrent() {
        guard let album = current else { return }
        if player.currentAlbumID == album.id {
            player.togglePlayPause()
        } else {
            player.play(albumID: album.id)
        }
    }

    private func openCurrent() {
        guard let album = current else { return }
        state.detailAlbum = IDRef(id: album.id)
    }
}

/// The 3D arrangement. Animatable so every frame of a spring re-lays-out covers along their path.
struct CoverFlowStage: View, Animatable {
    var position: Double
    let albums: [Album]
    let coverSize: CGFloat
    let playingAlbumID: UUID?
    let isPlaying: Bool
    let reduceMotion: Bool
    let onTap: (Int) -> Void

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        let count = albums.count
        let center = Int(position.rounded()).clamped(0, max(count - 1, 0))
        let lo = max(0, center - 8)
        let hi = min(count - 1, center + 8)
        ZStack {
            if count > 0 && lo <= hi {
                ForEach(lo...hi, id: \.self) { i in
                    let d = Double(i) - position
                    CoverItem(album: albums[i], size: coverSize,
                              isPlayingAlbum: albums[i].id == playingAlbumID, isPlaying: isPlaying,
                              emphasis: max(0, 1 - abs(d)), shade: min(abs(d), 1))
                        .modifier(CoverTransform(d: d, size: coverSize, reduceMotion: reduceMotion))
                        .zIndex(-abs(d))
                        .onTapGesture { onTap(i) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct CoverTransform: ViewModifier {
    let d: Double
    let size: CGFloat
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let a = abs(d)
        let s: Double = d < 0 ? -1 : 1
        let t = min(a, 1)
        let gap = Double(size) * 0.68
        let spacing = Double(size) * (reduceMotion ? 0.3 : 0.18)
        let x = a <= 1 ? s * a * gap : s * (gap + (a - 1) * spacing)
        let angle = (reduceMotion ? 0 : 62) * t
        let scale = 1 - (reduceMotion ? 0.22 : 0.1) * t
        let fade = (8.0 - a).clamped(0, 1)
        content
            .rotation3DEffect(.degrees(-s * angle), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.42)
            .scaleEffect(scale)
            .offset(x: x)
            .opacity(fade)
    }
}

struct CoverItem: View {
    let album: Album
    let size: CGFloat
    let isPlayingAlbum: Bool
    let isPlaying: Bool
    let emphasis: Double
    let shade: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: CoverFlowLayout.reflectionSpacing) {
            ArtworkView(album: album, pointSize: size, cornerRadius: 3)
                .frame(width: size, height: size)
                .overlay(Color.black.opacity((scheme == .dark ? 0.4 : 0.22) * shade).allowsHitTesting(false))
                .background(Color.black.opacity(0.001))
                .overlay(alignment: .topTrailing) {
                    if isPlayingAlbum {
                        NowPlayingBars(playing: isPlaying, color: .white, height: max(10, size * 0.035))
                            .padding(7)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                            .padding(size * 0.035)
                    }
                }
                .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.25), radius: 18 * emphasis + 6, y: 10 * emphasis + 4)
            // Subtle reflection on the "shelf".
            ArtworkView(album: album, pointSize: size, cornerRadius: 3)
                .frame(width: size, height: size)
                .scaleEffect(x: 1, y: -1)
                .frame(width: size, height: size * CoverFlowLayout.reflectionFraction, alignment: .top)
                .clipped()
                .opacity(1 - shade * 0.5)
                .mask(LinearGradient(colors: [.black.opacity(scheme == .dark ? 0.22 : 0.16), .clear], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: size)
    }
}

struct AlbumCaption: View {
    let album: Album?
    let compact: Bool
    let onPlay: () -> Void
    let onTracks: () -> Void
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let layout = compact
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 24))
            : AnyLayout(VStackLayout(spacing: 8))
        Group {
            if let album {
                let isCurrent = player.currentAlbumID == album.id
                layout {
                    VStack(alignment: compact ? .leading : .center, spacing: 4) {
                        if album.isDemo || album.missingMetadata {
                            HStack(spacing: 8) {
                                if album.isDemo { DemoChip() }
                                if album.missingMetadata {
                                    Label("Missing album info", systemImage: "exclamationmark.circle")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(height: 16)
                        }
                        Text(album.title)
                            .font(Typography.albumTitle(compact ? 24 : 26))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(album.artist)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(meta(album))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
                    HStack(spacing: 10) {
                        Button(action: onPlay) {
                            Label(isCurrent ? (player.isPlaying ? "Pause" : "Resume") : "Play",
                                  systemImage: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .help(isCurrent ? "Pause or resume this album" : "Play this album from the start")
                        Button(action: onTracks) {
                            Label("Tracks", systemImage: "list.bullet")
                        }
                        .buttonStyle(PillButtonStyle())
                        .help("Show the track list (Return)")
                        if isCurrent {
                            HStack(spacing: 6) {
                                NowPlayingBars(playing: player.isPlaying, color: Palette.accent(scheme), height: 11)
                                Text(player.isPlaying ? "Now Playing" : "Paused")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.accent(scheme))
                            }
                            .padding(.leading, 4)
                            .accessibilityElement(children: .combine)
                        } else if let playing = player.currentAlbum {
                            Button {
                                state.reveal(playing.id)
                            } label: {
                                HStack(spacing: 6) {
                                    NowPlayingBars(playing: player.isPlaying, color: .secondary, height: 10)
                                    Text("Playing: \(playing.title)").lineLimit(1)
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: 220)
                            .help("Go to the album that’s playing (⌘L)")
                        }
                    }
                    .fixedSize(horizontal: compact, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, compact ? 32 : 24)
        .animation(nil, value: album?.id)
    }

    private func meta(_ album: Album) -> String {
        var parts: [String] = []
        if let y = album.year { parts.append(String(y)) }
        let n = album.trackIDs.count
        parts.append(n == 1 ? "1 track" : "\(n) tracks")
        parts.append(formatLongDuration(library.totalDuration(album)))
        if let g = album.genre, g != "Demo" { parts.append(g) }
        return parts.joined(separator: " · ")
    }
}

/// A slim position bar for jumping through large collections.
struct CollectionScrubber: View {
    @ObservedObject var flow: CoverFlowController
    let count: Int

    var body: some View {
        Slider(value: Binding(get: { Double(flow.index) },
                              set: { flow.go(to: Int($0.rounded()), animated: false) }),
               in: 0...Double(max(count - 1, 1)))
            .controlSize(.mini)
            .opacity(0.55)
            .accessibilityLabel("Position in collection")
            .accessibilityValue("Album \(flow.index + 1) of \(count)")
    }
}

/// Captures trackpad and mouse-wheel scrolling over a region without blocking clicks.
struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (NSEvent) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((NSEvent) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                self.onScroll?(event)
                return nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
