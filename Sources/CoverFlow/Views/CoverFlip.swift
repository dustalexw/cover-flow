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

/// What turning a cover over (F, Option-click, or the Flip button) shows.
enum CoverTurnStyle: String, CaseIterable, Identifiable {
    /// Turn the sleeve over; disc art slides out to the right.
    case flipWithDiscs = "flip"
    /// Turn the sleeve over to the back cover only.
    case backOnly = "back"
    /// Open it like a CD jewel case: the lid swings open on its hinge and the disc
    /// sits in the tray.
    case jewelCase = "jewel"

    static let defaultsKey = "coverFlip.style"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .flipWithDiscs: return "Flip, with Discs Sliding Out"
        case .backOnly: return "Flip to the Back Cover Only"
        case .jewelCase: return "Open Like a Jewel Case"
        }
    }
}

/// A CD jewel case. At `openness` 0 it is just the cover, exactly as in Cover Flow;
/// opening swings the lid (front cover under clear plastic) out on its left hinge and
/// shows the disc in its tray. With Reduce Motion the lid fades instead of turning.
struct JewelCaseView: View, Animatable {
    var openness: Double
    let album: Album
    let size: CGFloat
    let reduceMotion: Bool

    var animatableData: Double {
        get { openness }
        set { openness = newValue }
    }

    private var hinge: CGFloat { size * 0.055 }
    private var angle: Double { -165 * openness.clamped(0, 1) }

    var body: some View {
        let shown = openness.clamped(0, 1)
        ZStack(alignment: .leading) {
            tray
                .opacity(shown > 0.001 ? 1 : 0)
            lid
                .modifier(LidMotion(angle: angle, openness: shown, reduceMotion: reduceMotion))
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown > 0.5 ? "Open jewel case of \(album.title)" : "Cover of \(album.title)")
        .accessibilityAddTraits(.isImage)
    }

    /// The lid: front cover under clear plastic, or (once past edge-on) its inside.
    private var lid: some View {
        let plastic = min(1, openness * 5)
        return ZStack {
            ZStack(alignment: .leading) {
                ArtworkView(album: album, pointSize: size, cornerRadius: 3)
                // Clear plastic: a soft diagonal sheen and edge, plus the hinge ribs.
                LinearGradient(stops: [.init(color: .white.opacity(0.22), location: 0),
                                       .init(color: .white.opacity(0.04), location: 0.42),
                                       .init(color: .clear, location: 0.55),
                                       .init(color: .white.opacity(0.06), location: 1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(plastic)
                    .allowsHitTesting(false)
                HingeRibs(width: hinge).opacity(plastic)
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.18 * plastic), lineWidth: 1)
            }
            .opacity(abs(angle) <= 90 ? 1 : 0)
            lidInside
                .scaleEffect(x: -1, y: 1)
                .opacity(abs(angle) > 90 ? 1 : 0)
        }
        .frame(width: size, height: size)
    }

    /// The inside of the lid: the booklet's back page behind the plastic and its tabs.
    private var lidInside: some View {
        let base = Color(nsColor: NSColor(hex: album.tintHex ?? "") ?? NSColor(white: 0.18, alpha: 1))
        return ZStack {
            LinearGradient(colors: [base.opacity(0.85), Color.black.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: size * 0.02) {
                Text(album.title)
                    .font(.system(size: max(7, size * 0.045), weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center).lineLimit(3)
                Text(album.artist.uppercased())
                    .font(.system(size: max(5, size * 0.026), weight: .medium)).tracking(size * 0.003).opacity(0.7)
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(size * 0.14)
            // The two clips that hold the booklet.
            VStack {
                Spacer()
                HStack(spacing: size * 0.5) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(width: size * 0.12, height: size * 0.025)
                    Capsule().fill(Color.white.opacity(0.18)).frame(width: size * 0.12, height: size * 0.025)
                }
                .padding(.bottom, size * 0.03)
            }
            LinearGradient(colors: [.white.opacity(0.14), .clear, .white.opacity(0.05)], startPoint: .topTrailing, endPoint: .bottomLeading)
            HStack { Spacer(); HingeRibs(width: hinge) }
            RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    /// The black tray with the disc held on its hub.
    private var tray: some View {
        let discSize = size * 0.86
        return ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
            // Moulded rings around the disc well.
            Circle().strokeBorder(Color.white.opacity(0.07), lineWidth: max(1, size * 0.006)).frame(width: size * 0.95, height: size * 0.95)
            Circle().fill(Color.black.opacity(0.35)).frame(width: discSize * 1.02, height: discSize * 1.02)
            Group {
                if let disc = album.discImages.first {
                    AlbumImageView(image: disc, pointSize: discSize, fill: true)
                } else {
                    PlainDisc(album: album, size: discSize)
                }
            }
            .frame(width: discSize, height: discSize)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: size * 0.02, y: size * 0.008)
            // The hub: clear plastic ring with the centre hole.
            Circle().fill(Color.white.opacity(0.10)).frame(width: size * 0.16, height: size * 0.16)
            Circle().strokeBorder(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: max(1, size * 0.012), dash: [max(1, size * 0.008), max(1, size * 0.006)]))
                .frame(width: size * 0.12, height: size * 0.12)
            Circle().fill(Color(white: 0.06)).frame(width: size * 0.05, height: size * 0.05)
            HStack { HingeRibs(width: hinge); Spacer() }
            RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .frame(width: size, height: size)
    }
}

/// Turns the lid on its left-edge hinge (or fades it with Reduce Motion).
private struct LidMotion: ViewModifier {
    let angle: Double
    let openness: Double
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(1 - openness)
        } else {
            content.rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.4)
        }
    }
}

/// The ribbed hinge strip along the case's spine.
private struct HingeRibs: View {
    let width: CGFloat
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.white.opacity(0.10), Color.black.opacity(0.25), Color.white.opacity(0.08)],
                           startPoint: .leading, endPoint: .trailing)
            VStack(spacing: max(1, width * 0.18)) {
                ForEach(0..<14, id: \.self) { _ in
                    Rectangle().fill(Color.white.opacity(0.10)).frame(height: max(0.5, width * 0.06))
                }
            }
            .padding(.vertical, width * 0.6)
        }
        .frame(width: width)
        .allowsHitTesting(false)
    }
}

/// A silver disc with the album printed on it, for albums without disc art.
struct PlainDisc: View {
    let album: Album
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(AngularGradient(colors: [Color(white: 0.82), Color(white: 0.62), Color(red: 0.75, green: 0.8, blue: 0.9),
                                                   Color(white: 0.9), Color(red: 0.9, green: 0.82, blue: 0.75), Color(white: 0.66), Color(white: 0.82)],
                                          center: .center))
            Circle().fill(Color.white.opacity(0.9)).frame(width: size * 0.62, height: size * 0.62)
            VStack(spacing: size * 0.012) {
                Text(album.title).font(.system(size: max(6, size * 0.05), weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                Text(album.artist).font(.system(size: max(5, size * 0.035))).lineLimit(1).opacity(0.7)
            }
            .foregroundStyle(.black.opacity(0.8))
            .frame(width: size * 0.5)
            .offset(y: -size * 0.16)
            Circle().fill(Color(white: 0.75)).frame(width: size * 0.2, height: size * 0.2)
        }
    }
}
