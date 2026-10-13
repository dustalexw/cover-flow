import Foundation

/// A single audio file in the collection. Files are referenced in place, never copied.
struct Track: Identifiable, Codable, Hashable {
    let id: UUID
    var fileURL: URL
    var title: String
    var artist: String
    var albumTitle: String
    var albumArtist: String?
    var trackNumber: Int?
    var discNumber: Int?
    var duration: Double
    var year: Int?
    var genre: String?
    var dateAdded: Date
    var isDemo: Bool
    var missingMetadata: Bool
    /// Used to detect the same recording imported from two different paths.
    var fingerprint: String

    var sortKey: (Int, Int, String) {
        (discNumber ?? 1, trackNumber ?? Int.max, fileURL.lastPathComponent.lowercased())
    }
}

/// A group of tracks presented as one record.
struct Album: Identifiable, Codable, Hashable {
    let id: UUID
    /// The key tracks are grouped by at import time. Stays stable when the user edits the display fields.
    var groupKey: String
    var title: String
    var artist: String
    var year: Int?
    var genre: String?
    var trackIDs: [UUID]
    var artworkFile: String?
    var artworkPixelWidth: Int?
    var artworkPixelHeight: Int?
    var artworkVersion: Int
    var tintHex: String?
    var dateAdded: Date
    var lastPlayed: Date?
    var isDemo: Bool
    var missingMetadata: Bool
    var userEdited: Bool
    /// Optional so libraries saved before album customization still decode unchanged.
    var appearance: AlbumAppearance? = nil

    var hasArtwork: Bool { artworkFile != nil }
    var artworkAspect: CGFloat {
        guard let w = artworkPixelWidth, let h = artworkPixelHeight, w > 0, h > 0 else { return 1 }
        return CGFloat(w) / CGFloat(h)
    }
    var artworkKey: String { "\(id.uuidString)-\(artworkVersion)" }
    var panelAppearance: AlbumAppearance { appearance ?? AlbumAppearance() }
}

struct AlbumAppearance: Codable, Hashable {
    var backgroundHex: String?
    var textHex: String?
    var accentHex: String?
    var sceneEnabled = true
    var sceneStrength = 0.55
    var sceneVariation = 0
    /// Optional so albums saved before this setting existed still decode. Off by default:
    /// the first refinement of an album takes several seconds of Neural Engine time.
    var sceneRefinement: Bool?

    var strength: Double { sceneStrength.isFinite ? min(1, max(0, sceneStrength)) : 0.55 }
    var refinesScene: Bool { sceneRefinement ?? false }
    var key: String {
        "\(backgroundHex ?? "auto")|\(textHex ?? "auto")|\(accentHex ?? "auto")|\(sceneEnabled)|\(strength)|\(sceneVariation)|\(refinesScene)"
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case artist, title, recentlyAdded, recentlyPlayed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .artist: return "Artist"
        case .title: return "Title"
        case .recentlyAdded: return "Recently Added"
        case .recentlyPlayed: return "Recently Played"
        }
    }
}

enum BrowseMode: String, CaseIterable, Identifiable {
    case coverFlow, grid
    var id: String { rawValue }
}

enum RepeatMode: String, Codable {
    case off, all, one
    var next: RepeatMode {
        switch self { case .off: return .all; case .all: return .one; case .one: return .off }
    }
    var label: String {
        switch self { case .off: return "Repeat Off"; case .all: return "Repeat All"; case .one: return "Repeat One" }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var label: String {
        switch self { case .dark: return "Dark"; case .light: return "Light"; case .system: return "Match System" }
    }
}

struct IDRef: Identifiable, Hashable {
    let id: UUID
}

enum AppPaths {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Test bundles can exercise the real app without changing the user's library.
        let override = Bundle.main.object(forInfoDictionaryKey: "CoverFlowDataDirectory") as? String
        let dir = override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? base.appendingPathComponent("CoverFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var library: URL { root.appendingPathComponent("Library.json") }
    static var playback: URL { root.appendingPathComponent("Playback.json") }
    static var artwork: URL {
        let dir = root.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var demo: URL {
        let dir = root.appendingPathComponent("Demo Collection", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
