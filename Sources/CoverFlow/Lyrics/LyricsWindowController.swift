import AppKit
import SwiftUI

/// A single reusable window observing the same playback clock as the collection.
@MainActor
final class LyricsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applyTheme() {
        switch AppEnvironment.shared.state.theme {
        case .dark: window?.appearance = NSAppearance(named: .darkAqua)
        case .light: window?.appearance = NSAppearance(named: .aqua)
        case .system: window?.appearance = nil
        }
    }

    private func makeWindow() -> NSWindow {
        let env = AppEnvironment.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Lyrics"
        window.identifier = NSUserInterfaceItemIdentifier("lyrics")
        window.minSize = NSSize(width: 440, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: LyricsView()
            .environmentObject(env.library).environmentObject(env.player).environmentObject(env.state))
        if !window.setFrameUsingName("CoverFlow.Lyrics.Frame") { window.center() }
        window.setFrameAutosaveName("CoverFlow.Lyrics.Frame")
        self.window = window
        applyTheme()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Release subscriptions and stop reading sidecars while the window is closed.
        window?.contentView = nil
        window = nil
    }
}
