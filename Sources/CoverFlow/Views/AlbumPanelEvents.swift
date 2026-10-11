import AppKit
import SwiftUI

/// Handle panel playback shortcuts before focused buttons see them, and consume
/// outside clicks so dismissing the panel never activates controls behind it.
struct AlbumPanelEvents: NSViewRepresentable {
    let enabled: Bool
    let onDismiss: () -> Void
    let onTogglePlayback: () -> Void

    func makeNSView(context: Context) -> EventMonitorView {
        let view = EventMonitorView()
        view.enabled = enabled
        view.onDismiss = onDismiss
        view.onTogglePlayback = onTogglePlayback
        return view
    }

    func updateNSView(_ view: EventMonitorView, context: Context) {
        view.enabled = enabled
        view.onDismiss = onDismiss
        view.onTogglePlayback = onTogglePlayback
    }

    static func dismantleNSView(_ view: EventMonitorView, coordinator: ()) { view.stopMonitoring() }

    final class EventMonitorView: NSView {
        var enabled = true
        var onDismiss: (() -> Void)?
        var onTogglePlayback: (() -> Void)?
        private var monitor: Any?
        private var dismissing = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            dismissing = false
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
                guard let self, self.enabled, !self.dismissing,
                      let sheet = self.window, let parent = sheet.sheetParent,
                      parent.attachedSheet === sheet, sheet.attachedSheet == nil else { return event }
                if event.type == .keyDown {
                    guard event.window === sheet, event.keyCode == 49,
                          event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
                    if !event.isARepeat { self.onTogglePlayback?() }
                    return nil
                }
                guard event.window === parent else { return event }
                let point = parent.convertPoint(toScreen: event.locationInWindow)
                guard !sheet.frame.contains(point) else { return event }
                self.dismissing = true
                DispatchQueue.main.async { [weak self] in self?.onDismiss?() }
                return nil
            }
        }

        // This view only observes events; controls within the panel keep their hit targets.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
