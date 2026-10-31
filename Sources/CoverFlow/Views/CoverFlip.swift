import SwiftUI
import AppKit

/// A two-sided record sleeve. `angle` runs 0 (front) … 180 (back) and is animatable,
/// so the face swaps exactly when the sleeve is edge-on. With Reduce Motion the
/// faces cross-fade instead of turning.
struct FlippableCover<Front: View, Back: View>: View, Animatable {
    var angle: Double
    let reduceMotion: Bool
    let front: Front
    let back: Back

    init(angle: Double, reduceMotion: Bool, @ViewBuilder front: () -> Front, @ViewBuilder back: () -> Back) {
        self.angle = angle
        self.reduceMotion = reduceMotion
        self.front = front()
        self.back = back()
    }

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        let progress = (angle / 180).clamped(0, 1)
        ZStack {
            if reduceMotion {
                front.opacity(1 - progress)
                back.opacity(progress)
            } else {
                front.opacity(angle <= 90 ? 1 : 0)
                // Pre-mirrored so it reads correctly once the sleeve has turned.
                back.scaleEffect(x: -1, y: 1).opacity(angle > 90 ? 1 : 0)
            }
        }
        .rotation3DEffect(.degrees(reduceMotion ? 0 : angle), axis: (x: 0, y: 1, z: 0), perspective: 0.42)
    }
}

/// Back cover or disc art from the Artwork folder, loaded like ArtworkView.
struct AlbumImageView: View {
    let image: AlbumImage
    var pointSize: CGFloat
    var cornerRadius: CGFloat = 3
    /// Fill the frame (for round disc art) instead of fitting inside it.
    var fill = false
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (key: String, image: NSImage)?

    private var key: String { "\(image.file)@\(ArtworkStore.bucket(for: pointSize * displayScale))" }

    var body: some View {
        let cached = library.artwork.cachedImage(image, pixels: pointSize * displayScale)
        let shown = (loaded?.key == key ? loaded?.image : nil) ?? cached
        ZStack {
            if let shown {
                Image(nsImage: shown)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: fill ? .fill : .fit)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius).fill(Color.primary.opacity(0.06))
            }
        }
        .task(id: key) {
            guard cached == nil else { return }
            if let decoded = await library.artwork.image(image, pixels: pointSize * displayScale) {
                withAnimation(.easeOut(duration: 0.2)) { loaded = (key, decoded) }
            }
        }
    }
}

/// The back of the sleeve: the scanned back cover when there is one, otherwise a
/// plain printed back with the title, artist and track list.
struct BackCoverView: View {
    let album: Album
    let size: CGFloat
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Group {
            if let back = album.backImage {
                AlbumImageView(image: back, pointSize: size)
            } else {
                printedBack
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Back cover of \(album.title)")
        .accessibilityAddTraits(.isImage)
    }

    private var printedBack: some View {
        let tracks = library.tracks(of: album)
        let shown = Array(tracks.prefix(18))
        let base = Color(nsColor: NSColor(hex: album.tintHex ?? "") ?? NSColor(white: 0.16, alpha: 1))
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [base.opacity(0.95), Color.black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: size * 0.012) {
                Text(album.title)
                    .font(.system(size: max(8, size * 0.052), weight: .semibold, design: .serif))
                    .lineLimit(2)
                Text(album.artist.uppercased())
                    .font(.system(size: max(6, size * 0.03), weight: .medium))
                    .tracking(size * 0.003)
                    .opacity(0.7)
                    .padding(.bottom, size * 0.02)
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: size * 0.02) {
                        Text("\(track.trackNumber ?? index + 1)")
                            .frame(width: size * 0.05, alignment: .trailing)
                            .opacity(0.6)
                        Text(track.title).lineLimit(1)
                        Spacer(minLength: size * 0.02)
                        Text(formatTime(track.duration)).opacity(0.6)
                    }
                    .font(.system(size: max(6, size * 0.028)).monospacedDigit())
                }
                if tracks.count > shown.count {
                    Text("+ \(tracks.count - shown.count) more")
                        .font(.system(size: max(6, size * 0.026)))
                        .opacity(0.6)
                }
                Spacer(minLength: 0)
                if let year = album.year {
                    Text(String(year)).font(.system(size: max(6, size * 0.026))).opacity(0.5)
                }
            }
            .foregroundStyle(.white)
            .padding(size * 0.08)
        }
    }
}

/// Disc art sliding out of the sleeve to the right when the cover is turned over.
/// Up to three discs fan out; disc 1 sits nearest the sleeve.
struct DiscStack: View {
    let album: Album
    let size: CGFloat
    let out: Bool
    let reduceMotion: Bool

    var body: some View {
        let discs = Array(album.discImages.prefix(3))
        let diameter = size * 0.94
        ZStack {
            ForEach(Array(discs.indices.reversed()), id: \.self) { i in
                AlbumImageView(image: discs[i], pointSize: diameter, fill: true)
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .offset(x: out ? size * (0.42 + 0.16 * CGFloat(i)) : 0)
                    .opacity(out ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? .easeOut(duration: 0.2)
                   : .spring(response: 0.55, dampingFraction: 0.82).delay(out ? 0.3 : 0), value: out)
        .allowsHitTesting(false)
    }
}
