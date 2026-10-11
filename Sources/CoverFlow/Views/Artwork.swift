import SwiftUI
import AppKit

/// Album artwork at a requested resolution, with a stable square footprint so nothing jumps while it loads.
struct ArtworkView: View {
    let album: Album?
    /// Approximate on-screen size in points; used to pick a sharp-enough cached thumbnail.
    var pointSize: CGFloat
    var cornerRadius: CGFloat = 4
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (key: String, image: NSImage)?

    private var key: String { album.map { "\($0.artworkKey)@\(ArtworkStore.bucket(for: pointSize * displayScale))" } ?? "none" }

    var body: some View {
        let cached = album.flatMap { library.artwork.cachedThumbnail($0, pixels: pointSize * displayScale) }
        let image = (loaded?.key == key ? loaded?.image : nil) ?? cached
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else if let album, album.hasArtwork {
                RoundedRectangle(cornerRadius: cornerRadius).fill(Color.primary.opacity(0.06))
            } else if let album {
                PlaceholderArtwork(title: album.title, artist: album.artist)
            } else {
                ZStack {
                    Color.primary.opacity(0.07)
                    Image(systemName: "music.note")
                        .font(.system(size: max(10, pointSize * 0.34), weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: key) {
            guard let album, album.hasArtwork, cached == nil else { return }
            if let img = await library.artwork.thumbnail(album, pixels: pointSize * displayScale) {
                withAnimation(.easeOut(duration: 0.2)) { loaded = (key, img) }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(album.map { $0.hasArtwork ? "Cover of \($0.title)" : "No cover for \($0.title)" } ?? "No artwork")
        .accessibilityAddTraits(.isImage)
    }
}

/// An attractive stand-in for a missing cover: a quiet colour field, record grooves, and the title.
struct PlaceholderArtwork: View {
    let title: String
    let artist: String

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let hue = Double((title + artist).stableHash % 360) / 360
            ZStack {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.32, brightness: 0.36),
                                        Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.42, brightness: 0.18)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                ZStack {
                    ForEach(0..<7, id: \.self) { i in
                        Circle()
                            .stroke(Color.white.opacity(0.05 + Double(i % 2) * 0.02), lineWidth: max(0.5, s * 0.004))
                            .frame(width: s * (0.3 + 0.085 * CGFloat(i)), height: s * (0.3 + 0.085 * CGFloat(i)))
                    }
                    Circle()
                        .fill(Color(hue: hue, saturation: 0.45, brightness: 0.62).opacity(0.85))
                        .frame(width: s * 0.2, height: s * 0.2)
                    Circle().fill(Color.black.opacity(0.6)).frame(width: s * 0.025, height: s * 0.025)
                }
                .offset(y: -s * 0.06)
                VStack(alignment: .leading, spacing: s * 0.01) {
                    Spacer()
                    Text(title.isEmpty ? "Untitled" : title)
                        .font(.system(size: max(8, s * 0.072), weight: .semibold, design: .serif))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .lineLimit(2)
                    if !artist.isEmpty && s > 90 {
                        Text(artist.uppercased())
                            .font(.system(size: max(6, s * 0.038), weight: .medium))
                            .tracking(s * 0.004)
                            .foregroundStyle(Color.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(s * 0.08)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A quiet backdrop with a tint drawn from the album's cover.
struct TintBackground: View {
    let tintHex: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tint = Palette.tint(hex: tintHex, scheme: scheme)
        ZStack {
            Palette.base(scheme)
            if let tint {
                RadialGradient(colors: [tint.opacity(scheme == .dark ? 0.42 : 0.30), tint.opacity(0)],
                               center: UnitPoint(x: 0.5, y: 0.18), startRadius: 0, endRadius: 900)
                LinearGradient(colors: [tint.opacity(scheme == .dark ? 0.10 : 0.08), .clear], startPoint: .top, endPoint: .bottom)
            }
        }
        .animation(.easeInOut(duration: 0.9), value: tintHex)
        .ignoresSafeArea()
    }
}
