import SwiftUI
import ImageIO
import UniformTypeIdentifiers
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

/// Find Artwork Online: search MusicBrainz, then pick the front cover, back cover and
/// disc art separately from every source found (Cover Art Archive editions, TheAudioDB,
/// fanart.tv), or from a file. Without `onUseExtras` (iPad, iPhone) only the front.
struct ArtworkDownloadView: View {
    typealias ExtraImage = (kind: AlbumImageKind, disc: Int?, data: Data)
    enum Choice: Equatable {
        case keep
        case online(ArtCandidate)
        case file(name: String, data: Data)
    }
    let album: Album
    let saveDescription: String
    /// How many discs the album has, for the disc picker.
    let discCount: Int
    let onUse: (Data) async throws -> Void
    var onUseExtras: (([ExtraImage]) async throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ExtraArtSettings.fanartKeyDefaultsKey) private var fanartKey = ""
    @State private var title: String
    @State private var artist: String
    @State private var results: [ArtworkMatch] = []
    @State private var selected: ArtworkMatch?
    @State private var candidates: [ArtCandidate] = []
    @State private var previews: [URL: Data] = [:]
    @State private var failedPreviews: Set<URL> = []
    @State private var front: Choice = .keep
    @State private var back: Choice = .keep
    @State private var discs: [Int: Choice] = [:]
    @State private var tab: ArtworkKind
    @State private var disc = 1
    @State private var importing = false
    @State private var searching = false
    @State private var loadingCandidates = false
    @State private var saving = false
    @State private var message: String?
    @State private var work: Task<Void, Never>?
    @State private var previewWork: Task<Void, Never>?

    init(album: Album, saveDescription: String, discCount: Int = 1, initialKind: ArtworkKind = .front,
         onUse: @escaping (Data) async throws -> Void,
         onUseExtras: (([ExtraImage]) async throws -> Void)? = nil) {
        self.album = album; self.saveDescription = saveDescription; self.discCount = max(1, discCount)
        self.onUse = onUse; self.onUseExtras = onUseExtras
        _title = State(initialValue: album.title); _artist = State(initialValue: album.artist)
        _tab = State(initialValue: onUseExtras == nil ? .front : initialKind)
    }

    private var kinds: [ArtworkKind] { onUseExtras == nil ? [.front] : ArtworkKind.allCases }
    private var busy: Bool { searching || saving }

    private var discSlots: [Int] {
        let found = candidates.filter { $0.kind == .disc }.compactMap(\.disc).max() ?? 1
        return Array(1...min(20, max(discCount, found, discs.keys.max() ?? 1)))
    }

    private var currentChoice: Choice {
        switch tab {
        case .front: return front
        case .back: return back
        case .disc: return discs[disc] ?? .keep
        }
    }

    private func setChoice(_ choice: Choice) {
        switch tab {
        case .front: front = choice
        case .back: back = choice
        case .disc: discs[disc] = choice
        }
    }

    /// Candidates for the open tab; disc art for the chosen disc first.
    private var tabCandidates: [ArtCandidate] {
        let list = candidates.filter { $0.kind == tab }
        guard tab == .disc else { return list }
        return list.filter { $0.disc == disc } + list.filter { $0.disc != disc }
    }

    /// Everything that will be saved, in order: front, back, then discs.
    private var plan: [(kind: ArtworkKind, disc: Int?, choice: Choice)] {
        var result: [(kind: ArtworkKind, disc: Int?, choice: Choice)] = []
        if front != .keep { result.append((.front, nil, front)) }
        if onUseExtras != nil {
            if back != .keep { result.append((.back, nil, back)) }
            for number in discs.keys.sorted() where discs[number] != .keep { result.append((.disc, number, discs[number]!)) }
        }
        return result
    }

    private func describe(_ choice: Choice) -> String {
        switch choice {
        case .keep: return "keep current"
        case .online(let candidate): return candidate.source.rawValue
        case .file(let name, _): return name
        }
    }

    private var summary: String {
        guard !plan.isEmpty else { return "Nothing chosen yet. Pick an album, then choose images, or choose files." }
        let parts = plan.map { item -> String in
            let what = item.kind == .disc ? "disc \(item.disc ?? 1)" : item.kind == .front ? "front" : "back"
            return "\(what) (\(describe(item.choice)))"
        }
        return "Will save: " + parts.joined(separator: ", ") + "."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Find Album Artwork").font(.title2.bold()); Spacer(); Button("Close") { work?.cancel(); dismiss() } }
            HStack {
                TextField("Album title", text: $title).accessibilityLabel("Album title")
                TextField("Artist", text: $artist).accessibilityLabel("Album artist")
                Button("Search", action: search).disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }.textFieldStyle(.roundedBorder).onSubmit(search)
            Text("Choose an album, then pick \(kinds.count > 1 ? "each kind of artwork" : "a cover") from the sources found, or use your own file. \(saveDescription)")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 18) {
                List(results) { match in
                    Button { load(match) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(match.title).fontWeight(.semibold)
                            Text(match.artist).font(.caption).foregroundStyle(.secondary)
                            Text(match.year).font(.caption2).foregroundStyle(.secondary)
                            if selected?.id == match.id { Text("Selected").font(.caption2).foregroundStyle(.tint) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(busy)
                }
                .frame(width: 230)
                .frame(minHeight: 300)
                chooser
            }
            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                if saving { ProgressView().controlSize(.small); Text("Downloading…").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Use Artwork") { save() }.buttonStyle(.borderedProminent).disabled(plan.isEmpty || busy)
            }
            Text("Album search by MusicBrainz. Images from the Cover Art Archive (every edition with scans) and TheAudioDB\(fanartKey.isEmpty ? "; add a fanart.tv key in Settings for its disc art" : " and fanart.tv"). Availability varies by album.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 880, height: 640)
        #endif
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count <= 40 * 1024 * 1024, Self.isImage(data) else {
                message = "That file isn’t an image Cover Flow can use."
                return
            }
            message = nil
            setChoice(.file(name: url.lastPathComponent, data: data))
        }
        .onDisappear { work?.cancel(); previewWork?.cancel() }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            if kinds.count > 1 {
                Picker("Artwork", selection: $tab) {
                    ForEach(kinds) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            HStack(alignment: .top, spacing: 16) {
                ArtworkDownloadPreview(data: imageData(currentChoice), circle: tab == .disc)
                    .frame(width: 220, height: 220)
                VStack(alignment: .leading, spacing: 8) {
                    if tab == .disc {
                        Picker("Disc", selection: $disc) {
                            ForEach(discSlots, id: \.self) { Text("Disc \($0)").tag($0) }
                        }
                        .frame(width: 150)
                    }
                    Text(choiceTitle).font(.headline)
                    Text(choiceDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Choose File…") { importing = true }.disabled(saving)
                    if currentChoice != .keep {
                        Button("Keep Current") { setChoice(.keep) }.disabled(saving)
                    }
                }
                Spacer(minLength: 0)
            }
            if loadingCandidates {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking in the Cover Art Archive, TheAudioDB\(fanartKey.isEmpty ? "" : " and fanart.tv")…").font(.caption).foregroundStyle(.secondary)
                }
            } else if selected != nil && tabCandidates.isEmpty {
                Text("No \(tab.label.lowercased()) found online for this album. Choose a file, or try another result.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !tabCandidates.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(tabCandidates) { tile($0) }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 140)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var choiceTitle: String {
        let what = tab == .disc ? "Disc \(disc)" : tab.label
        switch currentChoice {
        case .keep: return "\(what): keep current"
        case .online(let candidate): return "\(what): \(candidate.source.rawValue)"
        case .file(let name, _): return "\(what): \(name)"
        }
    }

    private var choiceDetail: String {
        switch currentChoice {
        case .keep:
            return tab == .front ? "The album keeps its cover." : "Nothing changes for this \(tab == .disc ? "disc" : "image")."
        case .online(let candidate):
            var parts = [candidate.note].filter { !$0.isEmpty }
            if candidate.kind == .disc, candidate.disc != disc { parts.append("Listed for disc \(candidate.disc ?? 1)") }
            return parts.isEmpty ? "Click another image below to change it." : parts.joined(separator: " · ")
        case .file:
            return "Your image file."
        }
    }

    private func imageData(_ choice: Choice) -> Data? {
        switch choice {
        case .keep: return nil
        case .online(let candidate): return previews[candidate.url]
        case .file(_, let data): return data
        }
    }

    private func tile(_ candidate: ArtCandidate) -> some View {
        let chosen = currentChoice == .online(candidate)
        return Button { setChoice(.online(candidate)) } label: {
            VStack(spacing: 3) {
                ZStack {
                    ArtworkDownloadPreview(data: previews[candidate.url], circle: candidate.kind == .disc)
                    if previews[candidate.url] == nil && !failedPreviews.contains(candidate.url) { ProgressView().controlSize(.small) }
                }
                .frame(width: 92, height: 92)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(chosen ? Color.accentColor : .clear, lineWidth: 3))
                Text(candidate.kind == .disc ? "Disc \(candidate.disc ?? 1) · \(candidate.source.rawValue)" : candidate.source.rawValue)
                    .font(.caption2.weight(chosen ? .semibold : .regular)).lineLimit(1)
                Text(candidate.note.isEmpty ? " " : candidate.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 104)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saving)
        .accessibilityLabel("\(candidate.kind.label) from \(candidate.source.rawValue) \(candidate.note)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func search() {
        guard !busy else { return }
        work?.cancel(); previewWork?.cancel()
        searching = true; message = nil; results = []; selected = nil; candidates = []
        work = Task {
            defer { searching = false }
            do {
                let matches = try await MusicLookupClient.shared.artwork(title: title, artist: artist)
                try Task.checkCancellation(); results = matches
            } catch is CancellationError { } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }

    /// Lists every image the album has online and picks sensible defaults. Choices made
    /// from files are kept.
    private func load(_ match: ArtworkMatch) {
        guard !busy else { return }
        work?.cancel(); previewWork?.cancel()
        selected = match; candidates = []; message = nil; loadingCandidates = true
        func clearOnline(_ choice: Choice) -> Choice { if case .online = choice { return .keep }; return choice }
        front = clearOnline(front); back = clearOnline(back); discs = discs.mapValues(clearOnline)
        let key = fanartKey
        work = Task {
            let found = await MusicLookupClient.shared.artCandidates(match, fanartKey: key)
            guard !Task.isCancelled, selected?.id == match.id else { return }
            loadingCandidates = false
            candidates = found
            let defaults = MusicLookupClient.defaultChoices(found)
            if front == .keep, let pick = defaults.front { front = .online(pick) }
            if onUseExtras != nil {
                if back == .keep, let pick = defaults.back { back = .online(pick) }
                for (number, pick) in defaults.discs where (discs[number] ?? .keep) == .keep { discs[number] = .online(pick) }
            }
            if found.isEmpty { message = "No artwork found online for this album. Try another result, or choose files." }
            loadPreviews()
        }
    }

    /// Small versions first, the full image if a small one isn't available.
    private func loadPreviews() {
        let order = candidates.filter { $0.kind == tab } + candidates.filter { $0.kind != tab }
        previewWork = Task {
            for candidate in order where previews[candidate.url] == nil {
                if Task.isCancelled { return }
                var data: Data?
                for url in [candidate.previewURL, candidate.url].compactMap({ $0 }) {
                    if let bytes = try? await MusicLookupClient.shared.image(url), Self.isImage(bytes) { data = bytes; break }
                    if Task.isCancelled { return }
                }
                if let data { previews[candidate.url] = data } else { failedPreviews.insert(candidate.url) }
            }
        }
    }

    private func save() {
        guard !busy, !plan.isEmpty else { return }
        saving = true; message = nil
        let items = plan
        let saveExtras = onUseExtras
        work = Task {
            defer { saving = false }
            do {
                var frontData: Data?
                var extras: [ExtraImage] = []
                var failed: [String] = []
                for item in items {
                    try Task.checkCancellation()
                    let data: Data
                    switch item.choice {
                    case .keep: continue
                    case .file(_, let bytes): data = bytes
                    case .online(let candidate):
                        do { data = try await MusicLookupClient.shared.image(candidate.url) }
                        catch { failed.append(item.kind == .disc ? "disc \(item.disc ?? 1)" : item.kind.label.lowercased()); continue }
                    }
                    if item.kind == .front { frontData = data }
                    else if let kind = item.kind.imageKind { extras.append((kind: kind, disc: item.disc, data: data)) }
                }
                if let frontData { try await onUse(frontData) }
                if let saveExtras, !extras.isEmpty { try await saveExtras(extras) }
                if failed.isEmpty { dismiss() }
                else { message = "Couldn’t download the \(failed.joined(separator: ", ")). Everything else was saved; try again or choose another image." }
            }
            catch is CancellationError { }
            catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }

    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0 && CGImageSourceGetType(source) != nil
    }
}

private struct ArtworkDownloadPreview: View {
    let data: Data?
    var circle = false
    var body: some View {
        Group {
            #if os(macOS)
            if let data, let image = NSImage(data: data) { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
            else { placeholder }
            #else
            if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().interpolation(.high).scaledToFit() }
            else { placeholder }
            #endif
        }.clipShape(RoundedRectangle(cornerRadius: circle ? 1000 : 8))
    }
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: circle ? 1000 : 8).fill(.quaternary)
            .overlay { Image(systemName: circle ? "opticaldisc" : "photo").font(.largeTitle).foregroundStyle(.secondary) }
    }
}
