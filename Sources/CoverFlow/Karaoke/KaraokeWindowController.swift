import AppKit
import SwiftUI

@MainActor
final class KaraokeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var keyMonitor: Any?
    func show() {
        let opened = window ?? makeWindow()
        opened.makeKeyAndOrderFront(nil)
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Karaoke"
        window.identifier = NSUserInterfaceItemIdentifier("karaoke")
        window.minSize = NSSize(width: 600, height: 740)
        window.isReleasedWhenClosed = false; window.delegate = self
        let content = NSHostingView(rootView: KaraokeView()
            .environmentObject(env.library).environmentObject(env.player)
            .environmentObject(env.state).environmentObject(env.karaoke))
        // Lyrics and the mixer scroll within the window instead of expanding its
        // intrinsic size beyond the screen when preparation finishes.
        content.sizingOptions = []
        window.contentView = content
        if !window.setFrameUsingName("CoverFlow.Karaoke.Frame") { window.center() }
        window.setFrameAutosaveName("CoverFlow.Karaoke.Frame")
        self.window = window; applyTheme()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window,
                  event.window === window, window.isKeyWindow,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  !((window.firstResponder as? NSTextView)?.isEditable ?? false),
                  let shortcut = KaraokeShortcut(event: event) else { return event }
            if !event.isARepeat { self.perform(shortcut) }
            return nil
        }
        return window
    }
    private func perform(_ shortcut: KaraokeShortcut) {
        let env = AppEnvironment.shared
        switch shortcut {
        case .playPause: env.player.togglePlayPause()
        case .original, .instrumental, .vocals:
            guard let track = env.player.currentTrack else { return }
            let mode: KaraokePlayback = shortcut == .original ? .original : (shortcut == .instrumental ? .instrumental : .vocals)
            guard mode == .original || env.karaoke.audio != nil else { return }
            env.karaoke.requestPlayback(mode, for: track) { [weak player = env.player] mode, audio in
                guard let player, player.currentTrackID == track.id else { return }
                if player.karaokePlayback != mode { player.setKaraokePlayback(mode, audio: audio) }
            }
        case .prepare:
            guard let track = env.player.currentTrack, env.karaoke.model != nil,
                  !env.karaoke.isProcessing, env.karaoke.audio == nil else { return }
            env.karaoke.prepare(track)
        }
    }
    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window?.contentView = nil; window = nil
    }
}

/// Window-local shortcuts run before a focused lyric or button can consume Space.
enum KaraokeShortcut: Equatable {
    case playPause, original, instrumental, vocals, prepare

    init?(event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        if event.keyCode == 49 { self = .playPause; return }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "1": self = .original
        case "2": self = .instrumental
        case "3": self = .vocals
        case "p": self = .prepare
        default: return nil
        }
    }
}
