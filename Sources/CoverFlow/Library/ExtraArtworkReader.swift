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
    private static let backWords: Set<String> = ["back", "backcover", "rear", "inlay", "tray", "traycard", "backinlay", "reverse"]
    private static let discWords: Set<String> = ["cd", "cdart", "disc", "disk", "discart", "vinyl", "media", "label", "lp", "medium"]
    private static let bookletWords: Set<String> = ["booklet", "insert", "leaflet", "liner", "linernotes"]
    /// Words that may follow a booklet keyword ("Liner Notes 2", "Booklet Page 3").
    private static let pageWords: Set<String> = ["notes", "page", "pages", "pg", "p"]
    /// Folders whose images are all booklet pages ("Booklet/01.jpg").
    static let bookletFolders: Set<String> = ["booklet", "booklets", "insert", "inserts", "liner notes", "linernotes"]
    static let maxBookletPages = 40
    /// Words that may follow the keyword ("Back Cover", "CD 2 Art", "Vinyl Side A").
    private static let trailingWords: Set<String> = ["art", "artwork", "image", "scan", "label", "side", "a", "b", "c", "d", "hq", "hires", "large"]
    /// Image folders commonly kept beside the audio ("Scans/Back.jpg").
    static let artworkFolders: Set<String> = ["scans", "scan", "artwork", "artworks", "art", "covers", "cover", "images", "pictures", "extras",
                                                "booklet", "booklets", "insert", "inserts", "liner notes", "linernotes"]

    /// Lowercased words of a file name, with letter/digit runs split ("CD2" → "cd", "2").
    static func words(_ name: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentIsDigit = false
        for ch in name.lowercased() {
            let isWordChar = ch.isLetter || ch.isNumber
            if !isWordChar || (!current.isEmpty && ch.isNumber != currentIsDigit) {
                if !current.isEmpty { result.append(current) }
                current = ""
            }
            if isWordChar { current.append(ch); currentIsDigit = ch.isNumber }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// What a folder image's name says it is, if anything. The keyword has to end the
    /// name (apart from a disc number or words like "cover"/"art"), so "Back in Black.jpg"
    /// stays a front cover while "Back in Black - Back.jpg" is a back cover. Disc art
    /// without a number ("cd.jpg") returns a nil disc.
    static func classify(fileName: String) -> (kind: AlbumImageKind, disc: Int?)? {
        let url = URL(fileURLWithPath: fileName)
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let tokens = words(url.deletingPathExtension().lastPathComponent)
        guard !tokens.isEmpty, !tokens.contains("front"), !tokens.contains("folder") else { return nil }
        // The last keyword, with only a number or descriptive words after it.
        for index in tokens.indices.reversed() {
            let token = tokens[index]
            let isBack = backWords.contains(token), isDisc = discWords.contains(token)
            if bookletWords.contains(token) {
                // "Booklet 03", "Liner Notes 2", "insert_p4".
                let rest = tokens[(index + 1)...]
                guard rest.allSatisfy({ Int($0) != nil || pageWords.contains($0) || trailingWords.contains($0) }) else { return nil }
                return (.booklet, rest.lazy.compactMap { Int($0) }.first.map { min(max(1, $0), maxBookletPages) })
            }
            guard isBack || isDisc else { continue }
            let rest = tokens[(index + 1)...]
            guard rest.allSatisfy({ Int($0) != nil || trailingWords.contains($0) || ($0 == "cover" && isBack) }) else { return nil }
            if isBack { return (.back, nil) }
            // "Disc 1 Label": the number may sit between two keywords.
            var start = index
            while start > 0, discWords.contains(tokens[start - 1]) || (Int(tokens[start - 1]) != nil && start > 1 && discWords.contains(tokens[start - 2])) {
                start -= 1
            }
            let number = tokens[start...].lazy.compactMap { Int($0) }.first.map { min(max(1, $0), 99) }
            return (.disc, number)
        }
        return nil
    }

    /// Whether a folder name is a per-disc folder ("CD1", "Disc 2").
    static func discFolderNumber(_ name: String) -> Int? {
        let tokens = words(name)
        guard tokens.count == 2, ["cd", "disc", "disk"].contains(tokens[0]), let n = Int(tokens[1]), n > 0 else { return nil }
        return n
    }

    /// Back and disc images beside the audio file, one per kind/disc (first by name).
    /// Also looks in artwork subfolders ("Scans", "Artwork", "Covers"…) and, for a
    /// per-disc folder like "CD2", in the album folder above it. Unnumbered disc art
    /// belongs to `trackDisc`.
    static func folderImages(for audio: URL, trackDisc: Int = 1) -> [Found] {
        let manager = FileManager.default
        let folder = audio.deletingLastPathComponent()
        func entries(_ dir: URL) -> [String] {
            ((try? manager.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        func subfolders(_ dir: URL) -> [URL] {
            entries(dir).filter { artworkFolders.contains($0.lowercased()) }.map { dir.appendingPathComponent($0, isDirectory: true) }
        }
        var places = [folder] + subfolders(folder)
        if discFolderNumber(folder.lastPathComponent) != nil {
            let parent = folder.deletingLastPathComponent()
            places += [parent] + subfolders(parent)
        }
        var found: [Found] = []
        for place in places {
            let isBookletFolder = place != folder && bookletFolders.contains(place.lastPathComponent.lowercased())
            for name in entries(place) {
                guard let match = classify(fileName: name)
                        ?? (isBookletFolder && imageExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
                            ? (kind: AlbumImageKind.booklet, disc: Int?.none) : nil)
                else { continue }
                let kind = match.kind
                let disc: Int?
                switch kind {
                case .back: disc = nil
                case .disc: disc = match.disc ?? trackDisc
                case .booklet:
                    // Unnumbered pages follow on in name order.
                    let used = Set(found.filter { $0.kind == .booklet }.compactMap(\.disc))
                    guard used.count < maxBookletPages else { continue }
                    disc = match.disc.flatMap { used.contains($0) ? nil : $0 } ?? (1...maxBookletPages).first { !used.contains($0) }
                }
                guard !found.contains(where: { $0.kind == kind && $0.disc == disc }) else { continue }
                let url = place.appendingPathComponent(name)
                guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size <= maxFileSize,
                      let data = try? Data(contentsOf: url) else { continue }
                found.append(Found(kind: kind, disc: disc, data: data))
            }
        }
        return found
    }

    /// Back cover, media and booklet ("Leaflet Page") pictures embedded in the file's
    /// tags. Media pictures are numbered from the track's disc, pages from 1, in tag order.
    static func embeddedImages(for audio: URL, trackDisc: Int = 1) -> [Found] {
        var pictures = [cf_picture](repeating: cf_picture(kind: 0, data: nil, size: 0), count: 24)
        let count = pictures.withUnsafeMutableBufferPointer { buffer in
            cf_artwork_read_extras(audio.path, buffer.baseAddress, buffer.count)
        }
        defer { pictures.withUnsafeMutableBufferPointer { cf_artwork_free_pictures($0.baseAddress, count) } }
        var found: [Found] = []
        var nextDisc = trackDisc
        var nextPage = 1
        for picture in pictures.prefix(count) {
            guard let bytes = picture.data, picture.size > 0 else { continue }
            let data = Data(bytes: bytes, count: picture.size)
            if picture.kind == 1 {
                if !found.contains(where: { $0.kind == .back }) { found.append(Found(kind: .back, disc: nil, data: data)) }
            } else if picture.kind == 2 {
                found.append(Found(kind: .disc, disc: nextDisc, data: data))
                nextDisc += 1
            } else if picture.kind == 3 {
                found.append(Found(kind: .booklet, disc: nextPage, data: data))
                nextPage += 1
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
