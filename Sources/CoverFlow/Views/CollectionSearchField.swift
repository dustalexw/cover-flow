import AppKit
import SwiftUI

/// A native search field keeps keyboard focus reliable inside the title toolbar.
struct CollectionSearchField: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.colorScheme) private var scheme
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focusRequest: focusRequest) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search music"
        field.font = .systemFont(ofSize: 12)
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.setAccessibilityLabel("Search albums, artists, and tracks")
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        field.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var focusRequest: Int
        init(text: Binding<String>, focusRequest: Int) { self.text = text; self.focusRequest = focusRequest }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
        @objc func searchChanged(_ field: NSSearchField) { text.wrappedValue = field.stringValue }
    }
}
