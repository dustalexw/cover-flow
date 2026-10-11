import AppKit
import SwiftUI

enum AlbumViewPreset: String, CaseIterable, Identifiable {
    case compact, large, immersive
    var id: String { rawValue }
    var title: String {
        switch self { case .compact: return "Compact"; case .large: return "Large"; case .immersive: return "Immersive" }
    }
    var symbol: String {
        switch self {
        case .compact: return "rectangle.portrait"
        case .large: return "rectangle.portrait.inset.filled"
        case .immersive: return "arrow.up.left.and.arrow.down.right"
        }
    }
}

/// Owns the Album View window: a scalable mini-player that can grow to fill most of the screen.
/// Playback lives in PlayerEngine, so opening, closing or resizing this window never interrupts it.
@MainActor
final class AlbumViewController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isOpen = false
    /// nil when the user has resized freely.
    @Published private(set) var preset: AlbumViewPreset?
    @Published var keepOnTop: Bool {
        didSet {
            UserDefaults.standard.set(keepOnTop, forKey: "albumView.keepOnTop")
            window?.level = keepOnTop ? .floating : .normal
        }
    }
    /// Artwork-focused state: controls fade after a few seconds of inactivity.
    @Published var focusMode: Bool {
        didSet { UserDefaults.standard.set(focusMode, forKey: "albumView.focusMode") }
    }
    @Published var chromeVisible = true

    private var window: NSWindow?
    private var programmaticResize = false
    private var beforeImmersive: (frame: NSRect, preset: AlbumViewPreset?)?
    private let frameName = "CoverFlow.AlbumView.Frame"

    override init() {
        let d = UserDefaults.standard
        keepOnTop = d.object(forKey: "albumView.keepOnTop") as? Bool ?? true
        focusMode = d.bool(forKey: "albumView.focusMode")
        preset = AlbumViewPreset(rawValue: d.string(forKey: "albumView.preset") ?? "") ?? .compact
        super.init()
    }

    func toggle() { isOpen ? close() : show() }

    func show() {
        let w = window ?? makeWindow()
        clampToScreen(w)
        w.makeKeyAndOrderFront(nil)
        isOpen = true
        persistOpenState()
    }

    func close() {
        window?.orderOut(nil)
        isOpen = false
        persistOpenState()
    }

    func persistOpenState() {
        UserDefaults.standard.set(isOpen, forKey: "albumView.open")
        UserDefaults.standard.set(isOpen, forKey: "albumViewOpen")
    }

    func apply(_ p: AlbumViewPreset) {
        if window == nil || !isOpen { show() }
        guard let w = window else { return }
        let screen = w.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        let size: NSSize
        switch p {
        case .compact:
            size = NSSize(width: 320, height: 430)
        case .large:
            size = NSSize(width: min(700, vf.width * 0.9), height: min(860, vf.height * 0.94))
        case .immersive:
            size = NSSize(width: vf.width * 0.96, height: vf.height * 0.96)
        }
        if p == .immersive && preset != .immersive {
            beforeImmersive = (w.frame, preset)
        }
        var center: NSPoint = p == .immersive ? NSPoint(x: vf.midX, y: vf.midY) : NSPoint(x: w.frame.midX, y: w.frame.midY)
        if p != .immersive, preset == .immersive, let before = beforeImmersive {
            center = NSPoint(x: before.frame.midX, y: before.frame.midY)
        }
        var frame = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        frame = clamp(frame, to: vf)
        programmaticResize = true
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        w.setFrame(frame, display: true, animate: animate)
        programmaticResize = false
        preset = p
        UserDefaults.standard.set(p.rawValue, forKey: "albumView.preset")
        if p == .immersive { Announcer.announce("Album View, immersive") }
    }

    /// Leaves Immersive, restoring the size and place the window had before.
    func exitImmersive() {
        guard let w = window, preset == .immersive else { return }
        if let before = beforeImmersive {
            let vf = (w.screen ?? NSScreen.main)?.visibleFrame ?? before.frame
            programmaticResize = true
            w.setFrame(clamp(before.frame, to: vf), display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            programmaticResize = false
            preset = before.preset
            UserDefaults.standard.set(before.preset?.rawValue ?? "", forKey: "albumView.preset")
            beforeImmersive = nil
        } else {
            apply(.large)
        }
    }

    /// Used by the on-screen resize grip.
    func resize(from start: NSRect, by delta: CGSize) {
        guard let w = window else { return }
        let vf = (w.screen ?? NSScreen.main)?.visibleFrame ?? start
        let minSize = w.minSize
        let width = (start.width + delta.width).clamped(minSize.width, vf.maxX - start.minX)
        let height = (start.height + delta.height).clamped(minSize.height, start.maxY - vf.minY)
        let frame = NSRect(x: start.minX, y: start.maxY - height, width: width, height: height)
        w.setFrame(frame, display: true)
        markCustom()
    }

    var currentFrame: NSRect { window?.frame ?? .zero }

    func applyTheme() {
        guard let w = window else { return }
        w.appearance = appearance()
    }

    func setChromeVisible(_ visible: Bool) {
        chromeVisible = visible
        guard let w = window else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let b = w.standardWindowButton(kind) else { continue }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                b.animator().alphaValue = visible ? 1 : 0
            }
        }
    }

    private func appearance() -> NSAppearance? {
        switch AppEnvironment.shared.state.theme {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }

    private func markCustom() {
        if preset != nil {
            preset = nil
            UserDefaults.standard.set("", forKey: "albumView.preset")
        }
    }

    private func makeWindow() -> NSWindow {
        let env = AppEnvironment.shared
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 430),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Album View"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = false
        w.minSize = NSSize(width: 260, height: 340)
        w.collectionBehavior = [.fullScreenNone, .managed]
        w.backgroundColor = NSColor(white: 0.06, alpha: 1)
        w.level = keepOnTop ? .floating : .normal
        w.appearance = appearance()
        w.delegate = self
        let root = AlbumViewScreen()
            .environmentObject(env.library)
            .environmentObject(env.player)
            .environmentObject(env.state)
            .environmentObject(self)
        w.contentView = NSHostingView(rootView: root)
        if !w.setFrameUsingName(frameName) {
            // First open: tuck the compact player into the lower-right corner, clear of the main window's controls.
            if let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
                w.setFrame(NSRect(x: vf.maxX - 340, y: vf.minY + 110, width: 320, height: 430), display: false)
            } else {
                w.center()
            }
        }
        w.setFrameAutosaveName(frameName)
        window = w
        return w
    }

    private func clamp(_ frame: NSRect, to vf: NSRect) -> NSRect {
        var f = frame
        f.size.width = min(f.width, vf.width)
        f.size.height = min(f.height, vf.height)
        f.origin.x = f.origin.x.clamped(vf.minX, vf.maxX - f.width)
        f.origin.y = f.origin.y.clamped(vf.minY, vf.maxY - f.height)
        return f
    }

    /// Keeps the window reachable if a display was disconnected or the saved frame is off-screen.
    private func clampToScreen(_ w: NSWindow) {
        let screens = NSScreen.screens
        let visible = screens.contains { $0.visibleFrame.intersection(w.frame).width > 80 && $0.visibleFrame.intersection(w.frame).height > 80 }
        let vf = (visible ? w.screen : NSScreen.main)?.visibleFrame ?? NSScreen.main?.visibleFrame
        guard let vf else { return }
        let f = clamp(w.frame, to: vf)
        if f != w.frame { w.setFrame(f, display: false) }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        persistOpenState()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if !programmaticResize { markCustom() }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if let w = window { clampToScreen(w) }
    }
}
