import SwiftUI

/// Colour themes taken from sipassgames.com's “Vivid” palettes: each game there has a
/// contrast-safe accent for light pages, three vivid colours for light pages and three
/// brighter ones for dark pages (`--sk-accent`, `--sk-v1…3`, `--sk-d1…3`). Cover Flow
/// uses the accent and first colour for controls and highlights, and tints its
/// near-black (or paper) background with them. Brass is Cover Flow's own original.
struct ColorTheme: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// The sipassgames.com game the palette comes from.
    let source: String
    /// Contrast-safe accent for light backgrounds.
    let accentLight: UInt32
    /// Vivid colours for light backgrounds (`--sk-v1…3`).
    let light: [UInt32]
    /// Vivid colours for dark backgrounds (`--sk-d1…3`).
    let dark: [UInt32]

    static let defaultsKey = "colorTheme"

    static let brass = ColorTheme(id: "brass", name: "Brass", source: "Cover Flow’s original",
                                  accentLight: 0x85570F, light: [0xC9A35C, 0xE0B970, 0x8C6A33],
                                  dark: [0xF2C47D, 0xE8C98F, 0xC9A35C])

    static let all: [ColorTheme] = [
        .brass,
        ColorTheme(id: "purple", name: "Purple", source: "Jippokeanue", accentLight: 0x9857CB,
                   light: [0x9125E4, 0xE830D5, 0x2420DF], dark: [0xB25AF6, 0xF764E8, 0x5652F4]),
        ColorTheme(id: "teal", name: "Teal", source: "Sippades", accentLight: 0x288169,
                   light: [0x25E4B2, 0x30B6E8, 0x20DF45], dark: [0x5AF6CD, 0x64CEF7, 0x52F472]),
        ColorTheme(id: "green", name: "Green", source: "Turokistan", accentLight: 0x29844A,
                   light: [0x25E469, 0x30E8D5, 0x43DF20], dark: [0x5AF692, 0x64F7E7, 0x70F452]),
        ColorTheme(id: "blue", name: "Blue", source: "BizossWizoss", accentLight: 0x3270DF,
                   light: [0x256AE4, 0x5230E8, 0x20CCDF], dark: [0x5A92F6, 0x7F64F7, 0x52E4F4]),
        ColorTheme(id: "orange", name: "Orange", source: "Offendio", accentLight: 0xC94412,
                   light: [0xE45925, 0xE8C530, 0xDF2053], dark: [0xF6855A, 0xF7DB64, 0xF4527E]),
        ColorTheme(id: "pink", name: "Pink", source: "Maxine", accentLight: 0xC23C91,
                   light: [0xE4259E, 0xE83042, 0xBE20DF], dark: [0xF65ABD, 0xF76472, 0xD852F4]),
        ColorTheme(id: "gold", name: "Gold", source: "Bogoss", accentLight: 0x94650E,
                   light: [0xE4A125, 0xC5E830, 0xDF3520], dark: [0xF6C05A, 0xDBF764, 0xF46452]),
        ColorTheme(id: "lime", name: "Lime", source: "Camickenickity", accentLight: 0x5F7825,
                   light: [0xACE425, 0x4FE830, 0xDFB020], dark: [0xC9F65A, 0x7DF764, 0xF4CC52]),
        ColorTheme(id: "violet", name: "Violet", source: "Twicketyforate", accentLight: 0x7256F5,
                   light: [0x7256F5, 0xA8B800, 0xE0457B], dark: [0xA796FF, 0xE6FF5C, 0xFF7AB0]),
    ]

    /// The chosen theme (Brass when none has been chosen).
    static var current: ColorTheme {
        let id = UserDefaults.standard.string(forKey: defaultsKey)
        return all.first { $0.id == id } ?? .brass
    }

    var isBrass: Bool { id == ColorTheme.brass.id }

    // MARK: Colours

    /// Controls, highlights and progress.
    func accent(dark isDark: Bool) -> Color { Color(rgb: isDark ? dark[0] : accentLight) }

    /// Text and glyphs on an accent-filled button.
    func onAccent(dark isDark: Bool) -> Color {
        if isBrass { return isDark ? Color(red: 0.10, green: 0.08, blue: 0.05) : .white }
        return isDark ? Color(rgb: 0x0B0B12) : .white
    }

    /// The window background: Cover Flow's near-black or paper, tinted toward the theme.
    func base(dark isDark: Bool) -> Color {
        if isBrass {
            return isDark ? Color(red: 0.063, green: 0.063, blue: 0.071) : Color(red: 0.955, green: 0.945, blue: 0.925)
        }
        return isDark ? Color.mix(0x0A0A12, dark[0], 0.08) : Color.mix(0xF7F4EF, light[0], 0.05)
    }

    /// Toolbars and the playback bar, slightly lifted from the base.
    func bar(dark isDark: Bool) -> Color {
        if isBrass {
            return isDark ? Color(red: 0.085, green: 0.085, blue: 0.095).opacity(0.92)
                : Color(red: 0.975, green: 0.968, blue: 0.952).opacity(0.94)
        }
        return (isDark ? Color.mix(0x12121B, dark[0], 0.10) : Color.mix(0xFBF9F5, light[0], 0.05)).opacity(isDark ? 0.92 : 0.94)
    }

    /// A deep background for the iPhone and iPad screens (navy in Brass).
    var deep: Color {
        isBrass ? Color(red: 0.045, green: 0.065, blue: 0.11) : Color.mix(0x08080F, dark[0], 0.16)
    }

    /// The three vivid colours as a gradient, as on sipassgames.com.
    func gradient(dark isDark: Bool) -> LinearGradient {
        LinearGradient(colors: (isDark ? dark : light).map { Color(rgb: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    init(rgb: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, opacity: opacity)
    }

    /// `a` blended toward `b` by `amount` (0…1), in sRGB.
    static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> Color {
        func channel(_ value: UInt32, _ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) / 255 }
        let t = min(max(amount, 0), 1)
        return Color(.sRGB, red: channel(a, 16) * (1 - t) + channel(b, 16) * t,
                     green: channel(a, 8) * (1 - t) + channel(b, 8) * t,
                     blue: channel(a, 0) * (1 - t) + channel(b, 0) * t, opacity: 1)
    }
}

/// Swatches for choosing a colour theme, in Settings on Mac, iPhone and iPad.
struct ColorThemePicker: View {
    @AppStorage(ColorTheme.defaultsKey) private var selection = ColorTheme.brass.id
    @Environment(\.colorScheme) private var scheme
    var columns = 5

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 12) {
            ForEach(ColorTheme.all) { theme in
                let chosen = theme.id == selection
                Button {
                    selection = theme.id
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(theme.gradient(dark: scheme == .dark))
                            .overlay(Circle().fill(theme.accent(dark: scheme == .dark)).padding(9))
                            .overlay(Circle().strokeBorder(chosen ? Color.primary : Color.primary.opacity(0.12),
                                                           lineWidth: chosen ? 2.5 : 1))
                            .overlay {
                                if chosen {
                                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(theme.onAccent(dark: scheme == .dark))
                                }
                            }
                            .frame(width: 40, height: 40)
                        Text(theme.name).font(.caption.weight(chosen ? .semibold : .regular)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(theme.name) colour theme")
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .help(theme.isBrass ? "Cover Flow’s original brass" : "From \(theme.source) on sipassgames.com")
            }
        }
    }
}
