import ImageIO
import SwiftUI
import UIKit

/// The scene size and the cover's rectangle in scene pixels, as on the Mac.
struct MobileSceneLayout: Equatable, Sendable {
  let size: CGSize
  let cover: CGRect
  var key: String {
    [size.width, size.height, cover.minX, cover.minY, cover.width, cover.height]
      .map { String(Int($0)) }.joined(separator: "-")
  }
  static func make(viewport: CGSize, cover: CGRect) -> Self? {
    guard viewport.width.isFinite, viewport.height.isFinite, viewport.width >= 128,
      viewport.height >= 128, cover.minX.isFinite, cover.minY.isFinite, cover.width.isFinite,
      cover.height.isFinite, cover.width > 0, cover.height > 0
    else { return nil }
    // The generator works up to 2160 × 1320 pixels; portrait displays scale to fit.
    let scale = min(2, 2160 / viewport.width, 1320 / viewport.height)
    let size = CGSize(width: floor(viewport.width * scale), height: floor(viewport.height * scale))
    let bounds = CGRect(origin: .zero, size: size)
    let area = CGRect(
      x: floor(cover.minX * scale), y: floor(cover.minY * scale),
      width: floor(cover.width * scale), height: floor(cover.height * scale)
    ).intersection(bounds)
    guard area.width >= 32, area.height >= 32 else { return nil }
    return Self(size: size, cover: area)
  }
}

/// Generated immersive scenes: the cover's own colors and texture extended across the
/// display around the cover's actual position. Saved as PNGs beside the artwork and
/// regenerated for a new cover or layout (rotating, folding or unfolding).
actor MobileSceneStore {
  static let shared = MobileSceneStore()
  private var images: [String: CGImage] = [:]
  private var recent: [String] = []
  private var pending: [String: Task<CGImage?, Never>] = [:]
  private var directory: URL { AppPaths.artwork.appendingPathComponent("Scenes", isDirectory: true) }

  func immersive(_ album: Album, layout: MobileSceneLayout) async -> CGImage? {
    guard let name = album.artworkFile else { return nil }
    let key = "\(album.artworkKey)-immersive-ios-v1-\(layout.key)"
    if let image = images[key] { return image }
    if let task = pending[key] { return await task.value }
    let destination = directory.appendingPathComponent(key + ".png")
    let source = AppPaths.artwork.appendingPathComponent((name as NSString).lastPathComponent)
    let folder = directory
    let prefix = album.id.uuidString + "-"
    let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
      if let saved = CGImageSourceCreateWithURL(destination as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(saved, 0, nil)
      {
        return image
      }
      guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
        let cover = CGImageSourceCreateThumbnailAtIndex(
          input, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
          ] as CFDictionary),
        !Task.isCancelled,
        let scene = AlbumSceneGenerator.generate(
          from: cover, seed: key.stableHash, size: layout.size, coverFrame: layout.cover)
      else { return nil }
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      if let writer = CGImageDestinationCreateWithURL(
        destination as CFURL, "public.png" as CFString, 1, nil)
      {
        CGImageDestinationAddImage(writer, scene, nil)
        CGImageDestinationFinalize(writer)
      }
      // Keep a few layouts per album (portrait, landscape, folded) and drop the rest.
      let files =
        (try? FileManager.default.contentsOfDirectory(
          at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      let mine = files.filter { $0.lastPathComponent.hasPrefix(prefix) }
        .sorted {
          ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast)
            > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
              ?? .distantPast)
        }
      for old in mine.dropFirst(4) { try? FileManager.default.removeItem(at: old) }
      return scene
    }
    pending[key] = task
    let image = await task.value
    pending[key] = nil
    if let image {
      images[key] = image
      recent.removeAll { $0 == key }
      recent.append(key)
      while recent.count > 3 { images[recent.removeFirst()] = nil }
    }
    return image
  }

  /// Removes scenes for albums no longer in the collection.
  func prune(keeping albumIDs: Set<UUID>) {
    let files =
      (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
      ?? []
    for file in files {
      let id = UUID(uuidString: String(file.lastPathComponent.prefix(36)))
      if id.map({ !albumIDs.contains($0) }) ?? true { try? FileManager.default.removeItem(at: file) }
    }
  }

  func remove(albumID: UUID) {
    let prefix = albumID.uuidString + "-"
    images = images.filter { !$0.key.hasPrefix(prefix) }
    recent.removeAll { $0.hasPrefix(prefix) }
    let files =
      (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
      ?? []
    for file in files where file.lastPathComponent.hasPrefix(prefix) {
      try? FileManager.default.removeItem(at: file)
    }
  }
}

/// Immersive background. A blurred cover shows while the scene is generated.
struct MobileImmersiveScene: View {
  let album: Album
  let viewport: CGSize
  let cover: CGRect
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var image: CGImage?
  @State private var imageKey = ""
  private var layout: MobileSceneLayout? { MobileSceneLayout.make(viewport: viewport, cover: cover) }
  var body: some View {
    ZStack {
      Color.black
      MobileArtwork(album: album, pixels: 400)
        .frame(width: max(viewport.width, viewport.height) * 1.3)
        .blur(radius: 70).opacity(0.7)
      if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFill()
          .frame(width: viewport.width, height: viewport.height)
          .transition(.opacity)
      }
      // Soft vignette so controls stay readable over bright scenes.
      RadialGradient(
        colors: [.clear, .black.opacity(0.35)], center: .center,
        startRadius: min(viewport.width, viewport.height) * 0.35,
        endRadius: max(viewport.width, viewport.height) * 0.75)
    }
    .frame(width: viewport.width, height: viewport.height).clipped()
    .ignoresSafeArea().accessibilityHidden(true)
    .task(id: "\(album.artworkKey)|\(layout?.key ?? "none")") {
      guard let layout, album.hasArtwork else {
        image = nil
        return
      }
      // Wait for rotation or fold animations to settle before generating.
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      let result = await MobileSceneStore.shared.immersive(album, layout: layout)
      guard !Task.isCancelled else { return }
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) { image = result }
    }
  }
}
