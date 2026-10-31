import Foundation

/// Whether "Keep media organized" copies imported files into the media folder or moves them there.
enum MediaImportMode: String, CaseIterable, Identifiable, Sendable {
    case copy, move
    var id: String { rawValue }
    var label: String { self == .copy ? "Copy files" : "Move files" }
    var pastTense: String { self == .copy ? "Copied" : "Moved" }
}

/// Plans and performs bringing audio files into the media folder, organized as
/// `Artist/Album/[Disc-]NN Title.ext`. macOS only; the iPad app always keeps its own copies.
enum MediaOrganizer {
    /// One file to bring in, with the names its new path is built from.
    struct Item: Sendable, Equatable {
        var trackID: UUID
        var source: URL
        var artist: String
        var album: String
        var title: String
        var discNumber: Int?
        var trackNumber: Int?
        /// Prefix track numbers with the disc number ("2-03") when the album spans discs.
        var multiDisc: Bool
    }

    struct Outcome: Sendable {
        /// New location of every file that was brought in.
        var moved: [UUID: URL] = [:]
        /// Files copied because moving them failed (for example on a read-only volume).
        var copiedInstead = 0
        var failures: [String] = []
    }

    static let maxComponentLength = 120

    /// Makes one path component safe for macOS: no slashes or colons, no leading dots,
    /// no control characters, trimmed, and not too long.
    static func sanitize(_ raw: String, fallback: String) -> String {
        var s = raw.precomposedStringWithCanonicalMapping
            .unicodeScalars
            .map { scalar -> String in
                if CharacterSet.controlCharacters.contains(scalar) { return " " }
                switch scalar {
                case "/", ":": return "_"
                default: return String(scalar)
                }
            }
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > maxComponentLength {
            s = String(s.prefix(maxComponentLength)).trimmingCharacters(in: .whitespaces)
        }
        while s.hasSuffix(".") { s.removeLast() }
        return s.isEmpty ? fallback : s
    }

    /// `Artist/Album/1-02 Title.flac`, relative to the media folder.
    static func relativePath(for item: Item) -> String {
        let artist = sanitize(item.artist, fallback: "Unknown Artist")
        let album = sanitize(item.album, fallback: "Unknown Album")
        var name = ""
        if let n = item.trackNumber {
            let number = String(format: "%02d", n)
            name = (item.multiDisc ? "\(item.discNumber ?? 1)-" : "") + number + " "
        }
        // Leave room for the number, a collision suffix and the extension.
        let title = sanitize(item.title, fallback: "Untitled")
        let base = String((name + title).prefix(maxComponentLength))
        let ext = item.source.pathExtension.lowercased()
        return [artist, album, ext.isEmpty ? base : base + "." + ext].joined(separator: "/")
    }

    static func isInside(_ url: URL, folder: URL) -> Bool {
        let file = url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return file.lowercased().hasPrefix(prefix.lowercased())
    }

    /// A destination that doesn't collide with an existing file or with one planned
    /// earlier in this batch ("Title 2.mp3", "Title 3.mp3", …). Comparison ignores
    /// case because APFS and HFS+ volumes usually do.
    static func destination(for item: Item, in folder: URL, taken: inout Set<String>,
                            exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let relative = relativePath(for: item)
        let first = folder.appendingPathComponent(relative)
        let directory = first.deletingLastPathComponent()
        let ext = first.pathExtension
        let stem = first.deletingPathExtension().lastPathComponent
        var candidate = first
        var n = 2
        while taken.contains(candidate.path.lowercased()) || exists(candidate) {
            let name = "\(stem) \(n)"
            candidate = directory.appendingPathComponent(ext.isEmpty ? name : name + "." + ext)
            n += 1
        }
        taken.insert(candidate.path.lowercased())
        return candidate
    }

    /// The `.lrc` sidecar next to an audio file (any letter case), if there is one.
    static func lyricsSidecar(for audio: URL) -> URL? {
        let fm = FileManager.default
        let exact = audio.deletingPathExtension().appendingPathExtension("lrc")
        if fm.fileExists(atPath: exact.path) { return exact }
        let wanted = exact.lastPathComponent.lowercased()
        let folder = audio.deletingLastPathComponent()
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().first { $0.lowercased() == wanted }.map { folder.appendingPathComponent($0) }
    }

    /// Copies or moves each file (and its lyrics sidecar) into `folder`. Files already
    /// inside the folder are left where they are. Runs synchronously; call it off the
    /// main thread. `progress` gets (done, total, file name) before each file.
    static func perform(_ items: [Item], into folder: URL, mode: MediaImportMode,
                        progress: (Int, Int, String) -> Void = { _, _, _ in }) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            outcome.failures = items.map { "\($0.source.lastPathComponent) (the media folder isn’t available: \(error.localizedDescription))" }
            return outcome
        }
        var taken = Set<String>()
        for (index, item) in items.enumerated() {
            progress(index, items.count, item.source.lastPathComponent)
            if isInside(item.source, folder: folder) { continue }
            guard fm.fileExists(atPath: item.source.path) else {
                outcome.failures.append("\(item.source.lastPathComponent) (file not found)")
                continue
            }
            let target = destination(for: item, in: folder, taken: &taken)
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let usedCopy = try transfer(item.source, to: target, mode: mode)
                if usedCopy && mode == .move { outcome.copiedInstead += 1 }
                if let lyrics = lyricsSidecar(for: item.source) {
                    let lyricsTarget = target.deletingPathExtension().appendingPathExtension("lrc")
                    if !fm.fileExists(atPath: lyricsTarget.path) {
                        _ = try? transfer(lyrics, to: lyricsTarget, mode: usedCopy ? .copy : mode)
                    }
                }
                outcome.moved[item.trackID] = target
            } catch {
                outcome.failures.append("\(item.source.lastPathComponent) (\(error.localizedDescription))")
            }
        }
        progress(items.count, items.count, "")
        return outcome
    }

    /// Returns true when the file ended up copied (including a move that fell back to a copy).
    private static func transfer(_ source: URL, to target: URL, mode: MediaImportMode) throws -> Bool {
        let fm = FileManager.default
        if mode == .move {
            do {
                try fm.moveItem(at: source, to: target)
                return false
            } catch {
                // The original couldn't be moved (read-only volume, locked file…). If a
                // partial copy was left behind, clear it before falling back to a copy.
                if fm.fileExists(atPath: source.path), fm.fileExists(atPath: target.path) {
                    try? fm.removeItem(at: target)
                }
                guard fm.fileExists(atPath: source.path) else { throw error }
            }
        }
        do {
            // On APFS this is a clone: instant, and it takes no extra space until either file changes.
            try fm.copyItem(at: source, to: target)
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
        return true
    }
}
