import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct LyricsDownloadView: View {
    let track: Track
    let onUse: (LyricMatch) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @State private var results: [LyricMatch] = []
    @State private var selected: LyricMatch?
    @State private var busy = false
    @State private var message: String?
    @State private var work: Task<Void, Never>?
    init(track: Track, onUse: @escaping (LyricMatch) async throws -> Void) {
        self.track = track; self.onUse = onUse
        _title = State(initialValue: track.title); _artist = State(initialValue: track.artist)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Find Lyrics").font(.title2.bold()); Spacer(); Button("Close") { dismiss() } }
            HStack {
                TextField("Track title", text: $title).accessibilityLabel("Track title")
                TextField("Artist", text: $artist).accessibilityLabel("Artist")
                Button("Search", action: search).disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }.textFieldStyle(.roundedBorder).onSubmit(search)
            Text("Search LRCLIB for \(track.title). Choose the recording and timing that fit your track.")
                .font(.caption).foregroundStyle(.secondary)
            List(results) { match in
                Button { selected = match } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(match.trackName).fontWeight(.semibold)
                            Text("\(match.artistName) · \(match.albumName)").font(.caption).foregroundStyle(.secondary)
                            Text("\(formatTime(match.duration)) · \(match.isSynced ? "Synced LRC" : "Plain lyrics")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selected?.id == match.id { Image(systemName: "checkmark.circle.fill") }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.vertical, 4)
            }.frame(minHeight: 180)
            if let selected {
                let document = LyricsDocument.parse(selected.text)
                ScrollView {
                    Text(document.isSynced ? document.cues.prefix(8).map(\.text).joined(separator: "\n") : document.plainText)
                        .font(.callout).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 120).padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                if busy { ProgressView().controlSize(.small); Button("Cancel") { work?.cancel(); dismiss() } }
                Spacer()
                Button(selected?.isSynced == true ? "Use Synced Lyrics" : "Use Lyrics") { save() }
                    .buttonStyle(.borderedProminent).disabled(selected == nil || busy)
            }
            Text("Lyrics provided by LRCLIB. Searches send the title and artist; your audio stays on this device.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(24)
        #if os(macOS)
        .frame(width: 620, height: 640)
        #endif
        .onDisappear { work?.cancel() }
    }
    private func search() {
        guard !busy else { return }
        work?.cancel(); busy = true; message = nil; selected = nil; results = []
        work = Task {
            defer { busy = false }
            do {
                let matches = try await MusicLookupClient.shared.lyrics(title: title, artist: artist, duration: track.duration)
                try Task.checkCancellation(); results = matches
            } catch is CancellationError { } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    private func save() {
        guard let selected, !busy else { return }
        busy = true; message = nil
        work = Task {
            defer { busy = false }
            do { try await onUse(selected); dismiss() }
            catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}

struct ArtworkDownloadView: View {
    let album: Album
    let saveDescription: String
    let onUse: (Data) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @State private var results: [ArtworkMatch] = []
    @State private var selected: ArtworkMatch?
    @State private var imageData: Data?
    @State private var busy = false
    @State private var message: String?
    @State private var work: Task<Void, Never>?
    init(album: Album, saveDescription: String, onUse: @escaping (Data) async throws -> Void) {
        self.album = album; self.saveDescription = saveDescription; self.onUse = onUse
        _title = State(initialValue: album.title); _artist = State(initialValue: album.artist)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Find Album Artwork").font(.title2.bold()); Spacer(); Button("Close") { dismiss() } }
            HStack {
                TextField("Album title", text: $title).accessibilityLabel("Album title")
                TextField("Artist", text: $artist).accessibilityLabel("Album artist")
                Button("Search", action: search).disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }.textFieldStyle(.roundedBorder).onSubmit(search)
            Text("Choose an album to preview its cover. \(saveDescription)").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 18) {
                List(results) { match in
                    Button { preview(match) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(match.title).fontWeight(.semibold)
                            Text(match.artist).font(.caption).foregroundStyle(.secondary)
                            Text(match.year).font(.caption2).foregroundStyle(.secondary)
                            if selected?.id == match.id { Text("Selected").font(.caption2).foregroundStyle(.tint) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(busy)
                }.frame(minHeight: 260)
                VStack(spacing: 12) {
                    ArtworkDownloadPreview(data: imageData).frame(width: 220, height: 220)
                    if let selected { Text(selected.title).font(.callout).multilineTextAlignment(.center) }
                }.frame(width: 220)
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                if busy { ProgressView().controlSize(.small); Button("Cancel") { work?.cancel(); dismiss() } }
                Spacer()
                Button("Use Artwork") { save() }.buttonStyle(.borderedProminent).disabled(imageData == nil || busy)
            }
            Text("Album search by MusicBrainz. Covers from the Cover Art Archive, up to 1200 pixels. Availability varies by edition.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(24)
        #if os(macOS)
        .frame(width: 740, height: 540)
        #endif
        .onDisappear { work?.cancel() }
    }
    private func search() {
        guard !busy else { return }
        work?.cancel(); busy = true; message = nil; results = []; selected = nil; imageData = nil
        work = Task {
            defer { busy = false }
            do {
                let matches = try await MusicLookupClient.shared.artwork(title: title, artist: artist)
                try Task.checkCancellation(); results = matches
            } catch is CancellationError { } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    private func preview(_ match: ArtworkMatch) {
        guard !busy else { return }
        selected = match; imageData = nil; busy = true; message = nil
        work = Task {
            defer { busy = false }
            do {
                let data = try await MusicLookupClient.shared.cover(match)
                try Task.checkCancellation(); imageData = data
            } catch is CancellationError { } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    private func save() {
        guard let imageData, !busy else { return }
        busy = true
        work = Task {
            defer { busy = false }
            do { try await onUse(imageData); dismiss() }
            catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}
private struct ArtworkDownloadPreview: View {
    let data: Data?
    var body: some View {
        Group {
            #if os(macOS)
            if let data, let image = NSImage(data: data) { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
            else { placeholder }
            #else
            if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().interpolation(.high).scaledToFit() }
            else { placeholder }
            #endif
        }.clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8).fill(.quaternary).overlay { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
    }
}
