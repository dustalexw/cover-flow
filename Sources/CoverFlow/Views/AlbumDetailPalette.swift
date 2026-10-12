import AppKit
import SwiftUI

/// iTunes-style album colors: the cover's left edge meets the track panel,
/// with foreground colors chosen for readable contrast instead of the app theme.
struct AlbumDetailPalette: Equatable {
    struct RGB: Equatable {
        let r: Double
        let g: Double
        let b: Double
        var color: Color { Color(red: r, green: g, blue: b) }
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return linear(r) * 0.2126 + linear(g) * 0.7152 + linear(b) * 0.0722
        }
        var saturation: Double { max(r, g, b) - min(r, g, b) }
        func contrast(with other: RGB) -> Double {
            (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
        }
        func mixed(with other: RGB, amount: Double) -> RGB {
            RGB(r: r * (1 - amount) + other.r * amount,
                g: g * (1 - amount) + other.g * amount,
                b: b * (1 - amount) + other.b * amount)
        }
        static let black = RGB(r: 0, g: 0, b: 0)
        static let white = RGB(r: 1, g: 1, b: 1)

        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
        init?(hex: String?) {
            guard let hex, let color = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return nil }
            self.init(r: color.redComponent, g: color.greenComponent, b: color.blueComponent)
        }
        var hex: String { NSColor(srgbRed: r, green: g, blue: b, alpha: 1).hexString }

        func readable(on background: RGB, minimum: Double = 4.8) -> RGB {
            guard contrast(with: background) < minimum else { return self }
            let ink: RGB = RGB.white.contrast(with: background) > RGB.black.contrast(with: background) ? .white : .black
            let target = min(minimum, ink.contrast(with: background))
            var low = 0.0, high = 1.0
            for _ in 0..<20 {
                let mid = (low + high) / 2
                if mixed(with: ink, amount: mid).contrast(with: background) >= target { high = mid }
                else { low = mid }
            }
            return mixed(with: ink, amount: high)
        }
    }

    let background: RGB
    let foreground: RGB
    let secondary: RGB
    let accent: RGB

    init(background: RGB, candidates: [RGB] = []) {
        self.background = background
        let ink: RGB = RGB.white.contrast(with: background) > RGB.black.contrast(with: background) ? .white : .black
        let softened = ink.mixed(with: background, amount: 0.08)
        foreground = softened.contrast(with: background) >= 4.5 ? softened : ink
        let muted = ink.mixed(with: background, amount: 0.28)
        secondary = muted.contrast(with: background) >= 4.5 ? muted : foreground
        accent = candidates.first { $0.saturation > 0.12 && $0.contrast(with: background) >= 4.5 } ?? foreground
    }

    private init(background: RGB, foreground: RGB, secondary: RGB, accent: RGB) {
        self.background = background; self.foreground = foreground
        self.secondary = secondary; self.accent = accent
    }

    func customized(_ appearance: AlbumAppearance) -> AlbumDetailPalette {
        let background = RGB(hex: appearance.backgroundHex) ?? self.background
        let foreground = (RGB(hex: appearance.textHex) ?? self.foreground).readable(on: background)
        let accent = (RGB(hex: appearance.accentHex) ?? self.accent).readable(on: background)
        return AlbumDetailPalette(background: background, foreground: foreground,
                                  secondary: foreground.mixed(with: background, amount: 0.22).readable(on: background),
                                  accent: accent)
    }

    static func fallback(_ album: Album) -> AlbumDetailPalette {
        if let hex = album.tintHex, let color = NSColor(hex: hex)?.usingColorSpace(.sRGB) {
            return AlbumDetailPalette(background: RGB(r: color.redComponent, g: color.greenComponent, b: color.blueComponent))
        }
        // Use the same hue as placeholder artwork when an album has no cover.
        let hue = Double((album.title + album.artist).stableHash % 360) / 360
        let color = NSColor(hue: hue, saturation: 0.32, brightness: 0.30, alpha: 1).usingColorSpace(.sRGB)!
        return AlbumDetailPalette(background: RGB(r: color.redComponent, g: color.greenComponent, b: color.blueComponent))
    }

    static func extract(from image: CGImage) -> AlbumDetailPalette? {
        let size = 64
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }
        struct Bucket {
            var count = 0.0
            var edgeCount = 0.0
            var r = 0.0, g = 0.0, b = 0.0
            var rgb: RGB { RGB(r: r / count, g: g / count, b: b / count) }
        }
        var buckets: [Int: Bucket] = [:]
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let alpha = Double(pixels[i + 3]) / 255
                guard alpha > 0.5 else { continue }
                let r = (Double(pixels[i]) / 255 / alpha).clamped(0, 1)
                let g = (Double(pixels[i + 1]) / 255 / alpha).clamped(0, 1)
                let b = (Double(pixels[i + 2]) / 255 / alpha).clamped(0, 1)
                let key = (Int(r * 15) << 8) | (Int(g * 15) << 4) | Int(b * 15)
                var bucket = buckets[key] ?? Bucket()
                bucket.count += 1
                bucket.edgeCount += x < 12 ? 1 : 0
                bucket.r += r; bucket.g += g; bucket.b += b
                buckets[key] = bucket
            }
        }
        // Stable ordering keeps equally common colors from changing between openings.
        let ordered = buckets.sorted { lhs, rhs in
            let l = lhs.value.edgeCount * 4 + lhs.value.count
            let r = rhs.value.edgeCount * 4 + rhs.value.count
            return l == r ? lhs.key < rhs.key : l > r
        }
        guard let background = ordered.first?.value.rgb else { return nil }
        let candidates = buckets.sorted {
            let l = $0.value.count * (0.25 + $0.value.rgb.saturation)
            let r = $1.value.count * (0.25 + $1.value.rgb.saturation)
            return l == r ? $0.key < $1.key : l > r
        }.map { $0.value.rgb }
        return AlbumDetailPalette(background: background, candidates: candidates)
    }
}

struct AlbumDetailButtonStyle: ButtonStyle {
    let palette: AlbumDetailPalette
    func makeBody(configuration: Configuration) -> some View {
        let surface = palette.background.mixed(with: configuration.isPressed ? palette.foreground : .white,
                                               amount: configuration.isPressed ? 0.08 : 0.12)
        let colors = AlbumDetailPalette(background: surface)
        return configuration.label
            .font(.custom("Helvetica Neue", size: 12).weight(.medium))
            .foregroundStyle(colors.foreground.color)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(surface.color)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.foreground.color.opacity(0.24)))
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.white.opacity(0.20)).frame(height: 1).padding(.horizontal, 3)
                    }
            }
            .shadow(color: .black.opacity(0.10), radius: 0.5, y: 1)
    }
}
