import SwiftUI
import AppKit

/// The contents of the Album View window: the playing cover as a large object, with restrained controls.
struct AlbumViewScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var controller: AlbumViewController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var controlsVisible = true
    @State private var lastActivity = Date()
    @FocusState private var focused: Bool

    private var immersive: Bool { controller.preset == .immersive }
    private var autoHide: Bool { (controller.focusMode || immersive) && player.hasTrack }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let narrow = w < 430
            let short = h < 520
            let controlsHeight: CGFloat = immersive ? min(118, h * 0.12) : (narrow || short ? 104 : 150)
            let topInset: CGFloat = immersive ? max(24, h * 0.025) : 38
            let artMax = CGSize(width: w - (narrow ? 28 : 56),
                                height: max(80, h - topInset - controlsHeight - (immersive ? 18 : 22)))
            ZStack {
                TintBackground(tintHex: player.currentAlbum?.tintHex)
                if !immersive {
                    // Lets the window be dragged by its background without fighting the controls.
                    WindowDragArea(onDoubleClick: nil)
                }

                VStack(spacing: 0) {
                    Spacer(minLength: topInset)
                    ZStack {
                        HeroArtwork(album: player.currentAlbum, maxSize: artMax, hasTrack: player.hasTrack)
                        if player.hasTrack {
                            WindowDragArea(onDoubleClick: { if immersive { controller.exitImmersive() } else { controller.apply(.immersive) } })
                                .frame(maxWidth: artMax.width, maxHeight: artMax.height)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(height: artMax.height)
                    Spacer(minLength: 6)
                    AlbumViewControls(compact: narrow || short, immersive: immersive)
                        .frame(height: controlsHeight)
                        .frame(maxWidth: immersive ? min(900, w * 0.7) : .infinity)
                        .padding(.horizontal, narrow ? 14 : 24)
                        .opacity(controlsVisible ? 1 : 0)
                        .allowsHitTesting(controlsVisible)
                        .accessibilityHidden(!controlsVisible)
                    Spacer(minLength: immersive ? 10 : 12)
                }

                // Top bar: title + size presets + options. Fades with the controls.
                VStack {
                    AlbumViewTopBar(narrow: narrow)
                        .padding(.leading, 78)
                        .padding(.trailing, 10)
                        .padding(.top, 6)
                        .opacity(controlsVisible ? 1 : 0)
                        .allowsHitTesting(controlsVisible)
                        .accessibilityHidden(!controlsVisible)
                    Spacer()
                }

                // Always-available exits, even when everything else has faded.
                if !controlsVisible {
                    VStack {
                        HStack {
                            Spacer()
                            HiddenStateButtons(immersive: immersive)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .transition(.opacity)
                }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ResizeGrip()
                    }
                }
            }
            .frame(width: w, height: h)
        }
        .ignoresSafeArea()
        .onContinuousHover { phase in
            if case .active = phase { poke() }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onAppear { focused = true; poke() }
        .onChange(of: autoHide) { poke() }
        .task(id: autoHide) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if autoHide && controlsVisible && Date().timeIntervalSince(lastActivity) > 3.2 {
                    withAnimation(.easeInOut(duration: reduceMotion ? 0.1 : 0.6)) { controlsVisible = false }
                    controller.setChromeVisible(false)
                }
            }
        }
        .preferredColorScheme(state.colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Album View")
    }

    private func poke() {
        lastActivity = Date()
        if !controlsVisible {
            withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.25)) { controlsVisible = true }
            controller.setChromeVisible(true)
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        poke()
        switch press.key {
        case .space:
            player.togglePlayPause(); return .handled
        case .leftArrow:
            if press.modifiers.contains(.option) { player.skip(by: -10) } else { player.previous() }
            return .handled
        case .rightArrow:
            if press.modifiers.contains(.option) { player.skip(by: 10) } else { player.next() }
            return .handled
        case .escape:
            if immersive { controller.exitImmersive() }
            else if controller.focusMode { controller.focusMode = false }
            else { controller.close() }
            return .handled
        default:
            break
        }
        switch press.characters.lowercased() {
        case "1": controller.apply(.compact); return .handled
        case "2": controller.apply(.large); return .handled
        case "3": controller.apply(.immersive); return .handled
        case "f": controller.focusMode.toggle(); return .handled
        default: return .ignored
        }
    }
}

/// The cover itself: full-resolution source, aspect preserved, never upscaled past 2× its pixels.
struct HeroArtwork: View {
    let album: Album?
    let maxSize: CGSize
    let hasTrack: Bool
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var shown: (key: String, image: NSImage)?

    var body: some View {
        let key = album?.artworkKey ?? "none"
        let size = fittedSize()
        ZStack {
            if !hasTrack {
                nothingPlaying
            } else if let shown, shown.key == key || album?.hasArtwork == true {
                Image(nsImage: shown.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .id(shown.key)
                    .transition(.opacity)
            } else if album?.hasArtwork == true {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
            } else {
                PlaceholderArtwork(title: album?.title ?? "", artist: album?.artist ?? "")
                    .id("placeholder-\(album?.id.uuidString ?? "")")
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: hasTrack ? 6 : 14, style: .continuous))
        .shadow(color: .black.opacity(hasTrack ? (scheme == .dark ? 0.6 : 0.3) : 0), radius: 30, y: 16)
        .animation(reduceMotion ? .linear(duration: 0.15) : .easeInOut(duration: 0.6), value: shown?.key)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: size)
        .task(id: key) {
            guard let album, album.hasArtwork else {
                shown = nil
                return
            }
            if let cached = library.artwork.cachedFull(album) {
                shown = (key, cached)
                return
            }
            // Show a sharp-enough thumbnail instantly, then swap in the original.
            if shown == nil, let quick = library.artwork.cachedThumbnail(album, pixels: 1100) {
                shown = (key + "-quick", quick)
            }
            if let full = await library.artwork.fullImage(album), !Task.isCancelled {
                shown = (key, full)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(album.map { "Cover of \($0.title) by \($0.artist)" } ?? "Nothing playing")
        .accessibilityAddTraits(.isImage)
    }

    private func fittedSize() -> CGSize {
        guard hasTrack else { return CGSize(width: min(maxSize.width, 300), height: min(maxSize.height, 260)) }
        let aspect = album?.artworkAspect ?? 1
        var w = min(maxSize.width, maxSize.height * aspect)
        var h = w / aspect
        if let px = album?.artworkPixelWidth, album?.hasArtwork == true {
            // Points on a Retina display are 2 px: allow at most 2× upsampling of the source pixels.
            let cap = CGFloat(px)
            if w > cap { w = cap; h = w / aspect }
        }
        return CGSize(width: max(1, w.rounded()), height: max(1, h.rounded()))
    }

    private var nothingPlaying: some View {
        VStack(spacing: 12) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Nothing playing")
                .font(Typography.albumTitle(18))
            if let browsed = library.album(state.browsedAlbumID) {
                Button {
                    player.play(albumID: browsed.id)
                } label: {
                    Label("Play \(browsed.title)", systemImage: "play.fill").lineLimit(1)
                }
                .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.raised(scheme))
    }
}

struct AlbumViewControls: View {
    let compact: Bool
    let immersive: Bool
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let track = player.currentTrack
        let album = player.currentAlbum
        VStack(spacing: compact ? 6 : 9) {
            if immersive {
                HStack(alignment: .center, spacing: 24) {
                    titles(track: track, album: album, align: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TransportControls(size: 32, showModes: true)
                    VolumeControl(showSlider: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                SeekBar(compact: false)
            } else {
                titles(track: track, album: album, align: .center)
                SeekBar(compact: compact)
                    .padding(.horizontal, compact ? 0 : 6)
                HStack {
                    if !compact { VolumeControl(showSlider: false) } else { Color.clear.frame(width: 1, height: 1) }
                    Spacer()
                    TransportControls(size: compact ? 28 : 32, showModes: !compact)
                    Spacer()
                    if !compact {
                        Button { state.reveal(player.currentAlbumID); NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil) } label: {
                            Image(systemName: "rectangle.stack")
                        }
                        .buttonStyle(IconButtonStyle(size: 28))
                        .disabled(!player.hasTrack)
                        .help("Show this album in the collection")
                        .accessibilityLabel("Show album in collection")
                    } else { Color.clear.frame(width: 1, height: 1) }
                }
            }
        }
    }

    @ViewBuilder
    private func titles(track: Track?, album: Album?, align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 2) {
            if compact {
                Text("Album View")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 1)
            }
            Text(track?.title ?? "Nothing playing")
                .font(Typography.albumTitle(compact ? 15 : (immersive ? 20 : 18)))
                .lineLimit(1)
            Text(track.map { "\($0.artist) — \(album?.title ?? $0.albumTitle)" } ?? "Album View shows the cover of whatever is playing")
                .font(.system(size: compact ? 11 : 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .multilineTextAlignment(align == .center ? .center : .leading)
        .accessibilityElement(children: .combine)
    }
}

struct AlbumViewTopBar: View {
    let narrow: Bool
    @EnvironmentObject private var controller: AlbumViewController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            if !narrow {
                Text("Album View")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(AlbumViewPreset.allCases) { p in
                    Button { controller.apply(p) } label: {
                        Group {
                            if narrow { Image(systemName: p.symbol) } else { Text(p.title) }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, narrow ? 7 : 9)
                        .padding(.vertical, 4)
                        .foregroundStyle(controller.preset == p ? Palette.onAccent(scheme) : Color.primary.opacity(0.85))
                        .background(Capsule().fill(controller.preset == p ? Palette.accent(scheme) : Color.clear))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("\(p.title) size (⌥⌘\(index(p) + 1))")
                    .accessibilityLabel("\(p.title) size")
                    .accessibilityAddTraits(controller.preset == p ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Capsule().fill(Palette.raised(scheme)))
            .overlay(Capsule().strokeBorder(Palette.hairline(scheme)))

            Button { controller.focusMode.toggle() } label: {
                Image(systemName: controller.focusMode ? "eye.slash" : "eye")
            }
            .buttonStyle(IconButtonStyle(size: 26, active: controller.focusMode))
            .help(controller.focusMode ? "Artwork focus is on: controls hide after a few seconds (F)" : "Artwork focus: hide controls when idle (F)")
            .accessibilityLabel("Artwork focus")
            .accessibilityValue(controller.focusMode ? "On" : "Off")

            Button { controller.keepOnTop.toggle() } label: {
                Image(systemName: controller.keepOnTop ? "pin.fill" : "pin")
            }
            .buttonStyle(IconButtonStyle(size: 26, active: controller.keepOnTop))
            .help(controller.keepOnTop ? "Floating above other windows" : "Keep on top")
            .accessibilityLabel("Keep on top")
            .accessibilityValue(controller.keepOnTop ? "On" : "Off")
        }
        .frame(height: 30)
    }

    private func index(_ p: AlbumViewPreset) -> Int { AlbumViewPreset.allCases.firstIndex(of: p) ?? 0 }
}

/// Shown when controls have faded: a quiet but always-reachable way out.
struct HiddenStateButtons: View {
    let immersive: Bool
    @EnvironmentObject private var controller: AlbumViewController
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            if immersive {
                Button { controller.exitImmersive() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .help("Exit Immersive (Esc)")
                    .accessibilityLabel("Exit immersive")
            }
            Button { controller.close() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 28))
                .help("Close Album View")
                .accessibilityLabel("Close Album View")
        }
        .padding(3)
        .background(Capsule().fill(.black.opacity(0.35)))
        .foregroundStyle(.white)
        .opacity(hover ? 1 : 0.4)
        .onHover { hover = $0 }
    }
}

/// A visible corner handle that resizes the window continuously.
struct ResizeGrip: View {
    @EnvironmentObject private var controller: AlbumViewController
    @State private var hover = false

    var body: some View {
        ZStack {
            ResizeHandleView(controller: controller)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .rotationEffect(.degrees(90))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .opacity(hover ? 0.95 : 0.45)
                .allowsHitTesting(false)
        }
        .frame(width: 26, height: 26)
        .padding(4)
        .onHover { hover = $0 }
        .help("Drag to resize")
        .accessibilityElement()
        .accessibilityLabel("Resize Album View")
        .accessibilityHint("Use the Compact, Large and Immersive buttons, or Option-Command 1, 2 and 3")
    }
}

struct ResizeHandleView: NSViewRepresentable {
    let controller: AlbumViewController

    func makeNSView(context: Context) -> HandleView {
        let v = HandleView()
        v.controller = controller
        return v
    }

    func updateNSView(_ nsView: HandleView, context: Context) { nsView.controller = controller }

    final class HandleView: NSView {
        weak var controller: AlbumViewController?
        private var startFrame: NSRect = .zero
        private var startMouse: NSPoint = .zero

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }

        override func mouseDown(with event: NSEvent) {
            startFrame = window?.frame ?? .zero
            startMouse = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            let now = NSEvent.mouseLocation
            let delta = CGSize(width: now.x - startMouse.x, height: startMouse.y - now.y)
            MainActor.assumeIsolated { controller?.resize(from: startFrame, by: delta) }
        }
    }
}

/// Drags the window (and optionally handles a double-click) from areas without controls.
struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> DragView {
        let v = DragView()
        v.onDoubleClick = onDoubleClick
        return v
    }

    func updateNSView(_ nsView: DragView, context: Context) { nsView.onDoubleClick = onDoubleClick }

    final class DragView: NSView {
        var onDoubleClick: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick {
                onDoubleClick()
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
