import Foundation
import CArtworkTags

/// Finds back cover and disc (CD/vinyl label) art for an album at import time: image
/// files beside the audio first, then pictures embedded in the audio file's tags.
enum ExtraArtworkReader {
    struct Found: Equatable {
        var kind: AlbumImageKind
        var disc: Int?
        var data: Data
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "tif", "tiff"]
    static let maxFileSize = 40 * 1024 * 1024
    private static let backNames: Set<String> = ["back", "backcover", "back cover", "back_cover", "back-cover", "rear", "inlay", "tray"]
    private static let discPattern = try! NSRegularExpression(
        pattern: #"^(?:cd|disc|disk|vinyl|media|label|lp)[ _-]?(\d{1,2})?$"#, options: [.caseInsensitive])

    /// What a folder image's base name says it is, if anything. Disc art without a
    /// number in its name ("cd.jpg") returns a nil disc.
    static func classify(fileName: String) -> (kind: AlbumImageKind, disc: Int?)? {
        let url = URL(fileURLWithPath: fileName)
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let base = url.deletingPathExtension().lastPathComponent.lowercased().trimmingCharacters(in: .whitespaces)
        if backNames.contains(base) { return (.back, nil) }
        let range = NSRange(base.startIndex..., in: base)
        guard let match = discPattern.firstMatch(in: base, range: range) else { return nil }
        let number = Range(match.range(at: 1), in: base).flatMap { Int(base[$0]) }
        return (.disc, number.map { max(1, $0) })
    }

    /// Back and disc images in the audio file's folder, one per kind/disc (first by name).
    /// Unnumbered disc art belongs to `trackDisc`.
    static func folderImages(for audio: URL, trackDisc: Int = 1) -> [Found] {
        let folder = audio.deletingLastPathComponent()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var found: [Found] = []
        for name in names {
            guard let match = classify(fileName: name) else { continue }
            let kind = match.kind
            let disc = kind == .disc ? (match.disc ?? trackDisc) : nil
            guard !found.contains(where: { $0.kind == kind && $0.disc == disc }) else { continue }
            let url = folder.appendingPathComponent(name)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size <= maxFileSize,
                  let data = try? Data(contentsOf: url) else { continue }
            found.append(Found(kind: kind, disc: disc, data: data))
        }
        return found
    }

    /// Back cover and media pictures embedded in the file's tags. Media pictures are
    /// numbered from the track's disc in tag order.
    static func embeddedImages(for audio: URL, trackDisc: Int = 1) -> [Found] {
        var pictures = [cf_picture](repeating: cf_picture(kind: 0, data: nil, size: 0), count: 8)
        let count = pictures.withUnsafeMutableBufferPointer { buffer in
            cf_artwork_read_extras(audio.path, buffer.baseAddress, buffer.count)
        }
        defer { pictures.withUnsafeMutableBufferPointer { cf_artwork_free_pictures($0.baseAddress, count) } }
        var found: [Found] = []
        var nextDisc = trackDisc
        for picture in pictures.prefix(count) {
            guard let bytes = picture.data, picture.size > 0 else { continue }
            let data = Data(bytes: bytes, count: picture.size)
            if picture.kind == 1 {
                if !found.contains(where: { $0.kind == .back }) { found.append(Found(kind: .back, disc: nil, data: data)) }
            } else if picture.kind == 2 {
                found.append(Found(kind: .disc, disc: nextDisc, data: data))
                nextDisc += 1
            }
        }
        return found
    }

    /// Folder images win over embedded ones for the same kind and disc.
    static func read(for audio: URL, trackDisc: Int = 1) -> [Found] {
        var result = folderImages(for: audio, trackDisc: trackDisc)
        for item in embeddedImages(for: audio, trackDisc: trackDisc)
        where !result.contains(where: { $0.kind == item.kind && $0.disc == item.disc }) {
            result.append(item)
        }
        return result
    }
}
