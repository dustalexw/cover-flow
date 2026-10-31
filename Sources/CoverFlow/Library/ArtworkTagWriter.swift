import CArtworkTags
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct EmbeddedArtwork: Sendable {
    let data: Data
    let mimeType: String
    let width: Int
    let height: Int

    static func prepare(_ data: Data) throws -> EmbeddedArtwork {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary) else { throw ArtworkError.notAnImage }
        let type = CGImageSourceGetType(source) as String?
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? image.width
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? image.height
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        // Preserve ordinary JPEG/PNG bytes. Other image types and oversized covers
        // become a standard, orientation-correct JPEG understood by music players.
        if (type == UTType.jpeg.identifier || type == UTType.png.identifier),
           data.count < 12 * 1024 * 1024, max(width, height) <= 8192, orientation == 1 {
            return EmbeddedArtwork(data: data, mimeType: type == UTType.png.identifier ? "image/png" : "image/jpeg",
                                   width: width, height: height)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ArtworkError.notAnImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length < 12 * 1024 * 1024 else { throw ArtworkError.notAnImage }
        return EmbeddedArtwork(data: output as Data, mimeType: "image/jpeg", width: image.width, height: image.height)
    }
}

struct ArtworkWriteReport: Identifiable, Sendable {
    let id = UUID()
    var updated = 0
    /// Files that already had the values (tag edits only).
    var unchanged = 0
    var failures: [String] = []
    var action = "Artwork embedded in"
    var summary: String {
        if updated == 0 && failures.isEmpty && unchanged > 0 { return "The audio files already had these details." }
        let success = "\(action) \(updated) audio file\(updated == 1 ? "" : "s")."
        return failures.isEmpty ? success : success + " \(failures.count) file\(failures.count == 1 ? " couldn’t" : "s couldn’t") be updated."
    }
}

struct ArtworkTagError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Serializes file changes, including replacements initiated from different windows.
actor ArtworkTagWriter {
    static let shared = ArtworkTagWriter()
    /// TagLib also writes Vorbis comments (Ogg, Speex), APE tags (Monkey's Audio, WavPack,
    /// Musepack), ASF (WMA), ID3v2 (TTA, DSD) and Matroska tags.
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "mp4", "flac", "wav", "wave", "aif", "aiff", "aifc", "opus", "ogg", "oga",
        "spx", "ape", "wv", "mpc", "wma", "asf", "tta", "dsf", "dff", "mka", "webm", "weba"
    ]

    func embed(_ artwork: EmbeddedArtwork, in urls: [URL]) -> ArtworkWriteReport {
        var report = ArtworkWriteReport()
        var seen = Set<String>()
        for input in urls {
            let url = input.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            do {
                try Self.replaceFile(at: url, artwork: artwork)
                report.updated += 1
            } catch {
                report.failures.append("\(input.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return report
    }

    static func replaceFile(at url: URL, artwork: EmbeddedArtwork) throws {
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw ArtworkTagError(message: "Cover Flow cannot embed artwork in this format.")
        }
        _ = try writeCopy(at: url) { path, message in
            artwork.data.withUnsafeBytes { bytes in
                cf_artwork_write(path, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                                 artwork.mimeType, Int32(artwork.width), Int32(artwork.height), message, 1024)
            } ? true : nil
        }
    }

    /// Writes text tags (TagLib property names → values; "" removes) to each file.
    /// Values a file already has are left alone, and such files aren't rewritten.
    func writeTags(_ changes: [(url: URL, fields: [String: String])]) -> ArtworkWriteReport {
        var report = ArtworkWriteReport(action: "Changes saved to")
        for change in changes where !change.fields.isEmpty {
            let url = change.url.resolvingSymlinksInPath().standardizedFileURL
            do {
                if try Self.writeTags(change.fields, at: url) { report.updated += 1 } else { report.unchanged += 1 }
            } catch {
                report.failures.append("\(change.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// Returns whether the file changed.
    static func writeTags(_ fields: [String: String], at url: URL) throws -> Bool {
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw ArtworkTagError(message: "Cover Flow can’t write tags in this format.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ArtworkTagError(message: "The audio file is missing.")
        }
        let entries = fields.sorted { $0.key < $1.key }
        return try writeCopy(at: url) { path, message in
            var changed = false
            let keys = entries.map { strdup($0.key) }, values = entries.map { strdup($0.value) }
            defer { (keys + values).forEach { free($0) } }
            let ok = keys.map { UnsafePointer($0) }.withUnsafeBufferPointer { k in
                values.map { UnsafePointer($0) }.withUnsafeBufferPointer { v in
                    cf_tags_write(path, k.baseAddress, v.baseAddress, entries.count, &changed, message, 1024)
                }
            }
            return ok ? changed : nil
        }
    }

    /// Edits a same-folder copy with `edit` (path, 1024-byte error buffer), then renames it
    /// over the original. `edit` returns nil on failure, false when nothing needed changing
    /// (the copy is discarded), true when the copy should replace the file.
    private static func writeCopy(at url: URL, edit: (String, UnsafeMutablePointer<CChar>) -> Bool?) throws -> Bool {
        let manager = FileManager.default
        let before = try manager.attributesOfItem(atPath: url.path)
        guard before[.type] as? FileAttributeType == .typeRegular else {
            throw ArtworkTagError(message: "The audio file is not a regular file.")
        }
        guard manager.isWritableFile(atPath: url.path), ((before[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o222 != 0,
              before[.immutable] as? Bool != true else {
            throw ArtworkTagError(message: "The audio file is locked or read-only.")
        }
        // Same-directory temporary files make the final rename atomic, including on
        // external volumes. Keep the extension so TagLib resolves the correct format.
        let ext = ["wave": "wav", "weba": "webm"][url.pathExtension.lowercased()] ?? url.pathExtension
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".coverflow-\(UUID().uuidString).\(ext)")
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: url, to: temporary)
        var message = [CChar](repeating: 0, count: 1024)
        let result = message.withUnsafeMutableBufferPointer { edit(temporary.path, $0.baseAddress!) }
        guard let changed = result else { throw ArtworkTagError(message: String(cString: message)) }
        guard changed else { return false }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        let after = try manager.attributesOfItem(atPath: url.path)
        for key: FileAttributeKey in [.systemNumber, .systemFileNumber, .size, .modificationDate] {
            guard (before[key] as? NSObject) == (after[key] as? NSObject) else {
                throw ArtworkTagError(message: "The file changed during the update. Try again.")
            }
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }
}
