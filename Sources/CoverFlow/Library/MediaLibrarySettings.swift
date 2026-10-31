import AppKit
import Foundation

/// "Keep media organized" preferences (macOS only).
@MainActor
final class MediaLibrarySettings: ObservableObject {
    static let keepOrganizedKey = "media.keepOrganized"
    static let modeKey = "media.importMode"
    static let folderKey = "media.folder"

    private let defaults: UserDefaults

    /// Off by default: Cover Flow references files where they are unless asked otherwise.
    @Published var keepOrganized: Bool {
        didSet { defaults.set(keepOrganized, forKey: Self.keepOrganizedKey) }
    }
    @Published var mode: MediaImportMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }
    @Published private(set) var folder: URL

    static var defaultFolder: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
        return music.appendingPathComponent("Cover Flow", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepOrganized = defaults.bool(forKey: Self.keepOrganizedKey)
        mode = defaults.string(forKey: Self.modeKey).flatMap(MediaImportMode.init(rawValue:)) ?? .copy
        folder = defaults.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
    }

    func setFolder(_ url: URL) {
        folder = url.standardizedFileURL
        defaults.set(folder.path, forKey: Self.folderKey)
    }

    func resetFolder() {
        folder = Self.defaultFolder
        defaults.removeObject(forKey: Self.folderKey)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Media Folder"
        panel.message = "Choose where Cover Flow keeps your organized music. Files are arranged by artist and album."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.fileExists(atPath: folder.path) ? folder : folder.deletingLastPathComponent()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.setFolder(url) }
        }
    }

    /// "Music › Cover Flow" style path for display.
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var path = folder.standardizedFileURL.path
        if path.hasPrefix(home + "/") { path = String(path.dropFirst(home.count + 1)) }
        return path.split(separator: "/").joined(separator: " › ")
    }
}
