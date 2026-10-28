import AppKit
import SwiftUI

struct ImmersiveSceneLayout: Equatable {
    let size: CGSize
    let cover: CGRect
    var key: String { [size.width, size.height, cover.minX, cover.minY, cover.width, cover.height].map { String(Int($0)) }.joined(separator: "-") }
    static func make(viewport: CGSize, cover: CGRect) -> Self? {
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width >= 128, viewport.height >= 128,
              cover.minX.isFinite, cover.minY.isFinite, cover.width.isFinite, cover.height.isFinite,
              cover.width > 0, cover.height > 0 else { return nil }
        let scale = min(2, 2160 / viewport.width, 1320 / viewport.height)
        let size = CGSize(width: floor(viewport.width * scale), height: floor(viewport.height * scale))
        let bounds = CGRect(origin: .zero, size: size)
        let area = CGRect(x: floor(cover.minX * scale), y: floor(cover.minY * scale),
                          width: floor(cover.width * scale), height: floor(cover.height * scale)).intersection(bounds)
        guard area.width >= 32, area.height >= 32 else { return nil }
        return Self(size: size, cover: area)
    }
}

/// The scene uses the exact foreground cover rectangle, rather than cropping the
/// album-panel scene (whose preserved cover is intentionally off to one side).
struct ImmersiveArtworkScene: View {
    let album: Album
    let viewport: CGSize
    let cover: CGRect
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: CGImage?
    @State private var shownKey = ""
    private var layout: ImmersiveSceneLayout? { .make(viewport: viewport, cover: cover) }
    private var key: String { album.artworkKey + "|" + album.panelAppearance.immersiveKey + "|" + (layout?.key ?? "none") }
    var body: some View {
        ZStack {
            Color.black
            // A cover-derived fallback fills the screen while the still scene is prepared.
            ArtworkView(album: album, pointSize: 800, cornerRadius: 0)
                .scaledToFill().frame(width: viewport.width, height: viewport.height)
                .blur(radius: 50).opacity(0.65).clipped()
            if let image, shownKey == key {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    .frame(width: viewport.width, height: viewport.height).transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.32), .clear, .clear, .black.opacity(0.48)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: viewport.width, height: viewport.height).clipped()
        .allowsHitTesting(false).accessibilityHidden(true)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: shownKey)
        .task(id: key) {
            guard let layout else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            let next = await library.artwork.scenes.immersiveScene(for: album, layout: layout)
            guard !Task.isCancelled else { return }
            image = next; shownKey = key
        }
    }
}
