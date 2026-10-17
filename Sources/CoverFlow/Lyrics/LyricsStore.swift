#if os(macOS)
import AppKit
#else
import Foundation
import Combine
#endif
import UniformTypeIdentifiers

struct LoadedLyrics: Sendable {
    let document: LyricsDocument
    let source: URL
    let imported: Bool
}

enum LyricsError: LocalizedError {
    case tooLarge, unreadable, empty, wrongType
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "That lyric file is too large. Choose an LRC file smaller than 2 MB."
        case .unreadable: return "That lyric file could not be read. Save it as UTF-8 or UTF-16 and try again."
        case .empty: return "That file has no readable lyrics. Check its text and timestamps, then try again."
        case .wrongType: return "Choose a file with the .lrc extension."
        }
    }
}

@MainActor
final class LyricsStore: ObservableObject {
    @Published private(set) var loaded: LoadedLyrics?
    @Published private(set) var loading = false
    @Published private(set) var trackID: UUID?
    @Published var errorMessage: String?
    private let directory: URL
    private var request = 0

    init(directory: URL) { self.directory = directory }

    func load(track: Track?) async {
        request += 1
        let token = request
        trackID = track?.id
        loaded = nil; errorMessage = nil
        guard let track else { loading = false; return }
        loading = true
        let directory = directory
        let result = await Task.detached(priority: .userInitiated) {
            Result { try Self.find(trackID: track.id, audioURL: track.fileURL, directory: directory) }
        }.value
        guard !Task.isCancelled, token == request else { return }
        loading = false
        switch result {
        case .success(let value): loaded = value
        case .failure(let error): errorMessage = error.localizedDescription
        }
    }

    #if os(macOS)
    func chooseFile(for track: Track) {
        let panel = NSOpenPanel()
        panel.title = "Import Lyrics for \(track.title)"
        panel.message = "Choose a timed .lrc file. A copy will be saved for this track."
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = track.fileURL.deletingLastPathComponent()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                do {
                    let directory = self.directory
                    _ = try await Task.detached(priority: .userInitiated) {
                        try Self.importFile(url, trackID: track.id, directory: directory)
                    }.value
                    // An open file picker can outlive a track change. Attach its
                    // file to the original track without replacing the new view.
                    if self.trackID == track.id { await self.load(track: track) }
                } catch {
                    if self.trackID == track.id { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    #endif

    nonisolated static func find(trackID: UUID, audioURL: URL, directory: URL) throws -> LoadedLyrics? {
        let imported = directory.appendingPathComponent(trackID.uuidString + ".lrc")
        if FileManager.default.fileExists(atPath: imported.path) {
            return LoadedLyrics(document: try read(imported), source: imported, imported: true)
        }
        let sibling = audioURL.deletingPathExtension().appendingPathExtension("lrc")
        let source: URL?
        if FileManager.default.fileExists(atPath: sibling.path) { source = sibling }
        else {
            // A .LRC sidecar should work on case-sensitive volumes too.
            let files = try? FileManager.default.contentsOfDirectory(at: audioURL.deletingLastPathComponent(),
                                                                     includingPropertiesForKeys: nil)
            source = files?.filter { $0.lastPathComponent.caseInsensitiveCompare(sibling.lastPathComponent) == .orderedSame }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }.first
        }
        guard let source else { return nil }
        return LoadedLyrics(document: try read(source), source: source, imported: false)
    }

    nonisolated static func read(_ url: URL) throws -> LyricsDocument {
        try parse(data: data(from: url))
    }

    nonisolated static func importFile(_ source: URL, trackID: UUID, directory: URL) throws -> LyricsDocument {
        guard source.pathExtension.lowercased() == "lrc" else { throw LyricsError.wrongType }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let data = try data(from: source)
        let document = try parse(data: data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(trackID.uuidString + ".lrc"), options: .atomic)
        return document
    }

    nonisolated private static func data(from url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2 * 1024 * 1024 else { throw LyricsError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= 2 * 1024 * 1024 else { throw LyricsError.tooLarge }
        return data
    }

    nonisolated private static func parse(data: Data) throws -> LyricsDocument {
        let utf16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        guard let text = String(data: data, encoding: utf16 ? .utf16 : .utf8) else { throw LyricsError.unreadable }
        let document = LyricsDocument.parse(text)
        guard !document.isEmpty else { throw LyricsError.empty }
        return document
    }
}
