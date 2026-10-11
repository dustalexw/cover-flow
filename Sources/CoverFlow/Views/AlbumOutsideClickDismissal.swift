import AppKit
import SwiftUI

/// Native sheets normally block the parent window. Consume a click in that
/// window to dismiss album tracks, without activating whatever is behind them.
struct AlbumOutsideClickDismissal: NSViewRepresentable {
    let enabled: Bool
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> ClickMonitorView {
        let view = ClickMonitorView()
        view.enabled = enabled
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ view: ClickMonitorView, context: Context) {
        view.enabled = enabled
        view.onDismiss = onDismiss
    }

    static func dismantleNSView(_ view: ClickMonitorView, coordinator: ()) { view.stopMonitoring() }

    final class ClickMonitorView: NSView {
        var enabled = true
        var onDismiss: (() -> Void)?
        private var monitor: Any?
        private var dismissing = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            dismissing = false
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, self.enabled, !self.dismissing,
                      let sheet = self.window, let parent = sheet.sheetParent,
                      parent.attachedSheet === sheet, sheet.attachedSheet == nil,
                      event.window === parent else { return event }
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
