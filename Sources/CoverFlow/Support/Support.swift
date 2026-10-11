import SwiftUI
import AppKit

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var normalizedKey: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Deterministic across launches (unlike `hashValue`).
    var stableHash: UInt64 {
        var h: UInt64 = 5381
        for b in utf8 { h = (h &* 33) &+ UInt64(b) }
        return h
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

extension Collection {
    subscript(safe i: Index) -> Element? { indices.contains(i) ? self[i] : nil }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let t = Int(seconds.rounded(.down))
    let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

func formatLongDuration(_ seconds: Double) -> String {
    let mins = Int((seconds / 60).rounded())
    if mins < 1 { return "\(Int(seconds)) sec" }
    if mins < 60 { return "\(mins) min" }
    return "\(mins / 60) hr \(mins % 60) min"
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded()).clamped(0, 255)
        let g = Int((c.greenComponent * 255).rounded()).clamped(0, 255)
        let b = Int((c.blueComponent * 255).rounded()).clamped(0, 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// The visual system: a quiet near-black (or warm paper) base, one brass accent, hairlines.
enum Palette {
    static func base(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.063, green: 0.063, blue: 0.071) : Color(red: 0.955, green: 0.945, blue: 0.925)
    }
    static func raised(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }
    static func raisedHover(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.09)
    }
    static func accent(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.95, green: 0.77, blue: 0.49) : Color(red: 0.52, green: 0.34, blue: 0.09)
    }
    static func onAccent(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.10, green: 0.08, blue: 0.05) : .white
    }
    static func hairline(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.09)
    }
    static func bar(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.085, green: 0.085, blue: 0.095).opacity(0.92) : Color(red: 0.975, green: 0.968, blue: 0.952).opacity(0.94)
    }

    /// Turns an artwork's average colour into a quiet background tint that keeps text legible.
    static func tint(hex: String?, scheme: ColorScheme) -> Color? {
        guard let hex, let ns = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let out: NSColor
        if scheme == .dark {
            out = NSColor(hue: h, saturation: min(s, 0.6), brightness: (b * 0.8).clamped(0.28, 0.6), alpha: 1)
        } else {
            out = NSColor(hue: h, saturation: min(s, 0.5), brightness: max(b, 0.72), alpha: 1)
        }
        return Color(nsColor: out)
    }
}

enum Typography {
    static func albumTitle(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
}

// MARK: - Button styles

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundStyle(prominent ? Palette.onAccent(scheme) : Color.primary)
                .background(
                    Capsule().fill(prominent
                                   ? AnyShapeStyle(Palette.accent(scheme).opacity(hover ? 1 : 0.9))
                                   : AnyShapeStyle(hover ? Palette.raisedHover(scheme) : Palette.raised(scheme)))
                )
                .overlay(Capsule().strokeBorder(Palette.hairline(scheme), lineWidth: prominent ? 0 : 1))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var active = false
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, size: size, active: active, prominent: prominent)
    }

    private struct IconBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let active: Bool
        let prominent: Bool
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(prominent ? Palette.onAccent(scheme) : (active ? Palette.accent(scheme) : Color.primary.opacity(0.88)))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(prominent
                                  ? AnyShapeStyle(Palette.accent(scheme).opacity(hover ? 1 : 0.92))
                                  : AnyShapeStyle(hover ? Palette.raisedHover(scheme) : Color.clear))
                )
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .opacity(enabled ? 1 : 0.35)
                .contentShape(Circle())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

struct DemoChip: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text("DEMO")
            .font(.system(size: 9.5, weight: .bold))
            .tracking(1.2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .foregroundStyle(Palette.accent(scheme))
            .overlay(Capsule().strokeBorder(Palette.accent(scheme).opacity(0.6), lineWidth: 1))
            .accessibilityLabel("Demonstration content")
    }
}

/// Three animated bars marking the album that is currently playing.
struct NowPlayingBars: View {
    var playing: Bool
    var color: Color
    var height: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !playing || reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = t * (2.6 + Double(i) * 0.9) + Double(i) * 1.3
                    let level = (playing && !reduceMotion) ? (0.35 + 0.65 * abs(sin(phase))) : [0.55, 0.9, 0.4][i]
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color)
                        .frame(width: height * 0.22, height: max(2, height * level))
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// Announces meaningful changes to VoiceOver without spamming.
enum Announcer {
    private static var last: (String, Date)?
    static func announce(_ text: String) {
        if let last, last.0 == text, Date().timeIntervalSince(last.1) < 2 { return }
        last = (text, Date())
        let element: Any = NSApp.mainWindow ?? NSApp as Any
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }
}
