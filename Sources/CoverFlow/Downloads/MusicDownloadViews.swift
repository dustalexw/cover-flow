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
/// disc art separately from the sources you turn on (Cover Art Archive editions,
/// TheAudioDB, fanart.tv), or from a file. The album's current art is shown and kept
/// unless you replace or remove it. Without `onUseExtras` (iPad, iPhone) only the front.
struct ArtworkDownloadView: View {
    typealias ExtraImage = (kind: AlbumImageKind, disc: Int?, data: Data)
    enum Choice: Equatable {
        case keep
        case remove
        case online(ArtCandidate)
        case file(name: String, data: Data)
    }
    let album: Album
    let saveDescription: String
    /// How many discs the album has, for the disc picker.
    let discCount: Int
    /// Where the album's current image of a kind (and disc) is stored, to show it.
    let currentImage: ((ArtworkKind, Int?) -> URL?)?
    let onUse: (Data) async throws -> Void
    var onUseExtras: (([ExtraImage]) async throws -> Void)? = nil
    var onRemoveExtras: (([(kind: AlbumImageKind, disc: Int?)]) async -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ExtraArtSettings.fanartKeyDefaultsKey) private var fanartKey = ""
    @AppStorage("artworkDownload.wantFront") private var wantFront = true
    @AppStorage("artworkDownload.wantBack") private var wantBack = true
    @AppStorage("artworkDownload.wantDisc") private var wantDisc = true
    @AppStorage("artworkDownload.useArchive") private var useArchive = true
    @AppStorage("artworkDownload.useAudioDB") private var useAudioDB = true
    @AppStorage("artworkDownload.useFanart") private var useFanart = true
    @State private var title: String
    @State private var artist: String
    @State private var results: [ArtworkMatch] = []
    @State private var selected: ArtworkMatch?
    /// Each source's images for the selected album, as they arrive.
    @State private var found: [ArtSource: [ArtCandidate]] = [:]
    /// Whether the archive's results include other editions.
    @State private var archiveHasEditions = false
    @State private var loading: Set<ArtSource> = []
    @State private var previews: [URL: Data] = [:]
    @State private var failedPreviews: Set<URL> = []
    @State private var current: [String: Data] = [:]
    @State private var front: Choice = .keep
    @State private var back: Choice = .keep
    @State private var discs: [Int: Choice] = [:]
    /// Choices Cover Flow made, which it may change as more sources answer.
    @State private var autoPicked: Set<String> = []
    @State private var tab: ArtworkKind
    @State private var disc = 1
    /// Highest disc slot added by hand with Add Disc.
    @State private var addedDiscs = 1
    @State private var importing = false
    @State private var searching = false
    @State private var saving = false
    @State private var searched = false
    @State private var message: String?
    @State private var searchWork: Task<Void, Never>?
    @State private var sourceWork: [ArtSource: Task<Void, Never>] = [:]
    @State private var previewWork: Task<Void, Never>?
    @State private var saveWork: Task<Void, Never>?

    init(album: Album, saveDescription: String, discCount: Int = 1, initialKind: ArtworkKind = .front,
         currentImage: ((ArtworkKind, Int?) -> URL?)? = nil,
         onUse: @escaping (Data) async throws -> Void,
         onUseExtras: (([ExtraImage]) async throws -> Void)? = nil,
         onRemoveExtras: (([(kind: AlbumImageKind, disc: Int?)]) async -> Void)? = nil) {
        self.album = album; self.saveDescription = saveDescription; self.discCount = max(1, discCount)
        self.currentImage = currentImage
        self.onUse = onUse; self.onUseExtras = onUseExtras; self.onRemoveExtras = onRemoveExtras
        _title = State(initialValue: MusicLookupClient.searchTitle(album.title)); _artist = State(initialValue: album.artist)
        _tab = State(initialValue: onUseExtras == nil ? .front : initialKind)
    }

    // MARK: What to look for

    private var kinds: [ArtworkKind] { onUseExtras == nil ? [.front] : ArtworkKind.allCases }
    private func wants(_ kind: ArtworkKind) -> Bool {
        guard kinds.contains(kind) else { return false }
        if kinds.count == 1 { return true }
        switch kind { case .front: return wantFront; case .back: return wantBack; case .disc: return wantDisc }
    }
    private var sources: [ArtSource] {
        var list: [ArtSource] = []
        if useArchive { list.append(.coverArtArchive) }
        if useAudioDB { list.append(.theAudioDB) }
        if useFanart && !fanartKey.trimmingCharacters(in: .whitespaces).isEmpty { list.append(.fanartTV) }
        return list
    }
    /// Other archive editions are only worth the requests for back and disc art.
    private var needsEditions: Bool { wants(.back) || wants(.disc) }
    private var busy: Bool { searching || saving }

    /// Images from the sources that are on, for the kinds you want, without duplicates.
    private var candidates: [ArtCandidate] {
        var seen = Set<URL>()
        return sources.flatMap { found[$0] ?? [] }.filter { wants($0.kind) && seen.insert($0.url).inserted }
    }

    /// The album's discs, plus any that already have art or a choice, plus ones added
    /// with Add Disc. A single-disc album gets one slot, whatever the sources list.
    private var discSlots: [Int] {
        let have = album.discImages.compactMap(\.disc).max() ?? 1
        let chosen = discs.filter { $0.value != .keep }.keys.max() ?? 1
        return Array(1...min(20, max(discCount, have, chosen, addedDiscs)))
    }

    // MARK: Choices

    private func key(_ kind: ArtworkKind, _ disc: Int?) -> String { kind == .disc ? "disc\(disc ?? 1)" : kind.rawValue }
    private var currentKey: String { key(tab, disc) }

    private func hasCurrent(_ kind: ArtworkKind, _ disc: Int?) -> Bool {
        switch kind {
        case .front: return album.hasArtwork
        case .back: return album.backImage != nil
        case .disc: return album.discImages.contains { ($0.disc ?? 1) == (disc ?? 1) }
        }
    }

    private func choice(_ kind: ArtworkKind, _ disc: Int?) -> Choice {
        switch kind {
        case .front: return front
        case .back: return back
        case .disc: return discs[disc ?? 1] ?? .keep
        }
    }

    private func set(_ kind: ArtworkKind, _ disc: Int?, _ value: Choice, auto: Bool = false) {
        switch kind {
        case .front: front = value
        case .back: back = value
        case .disc: discs[disc ?? 1] = value
        }
        if auto { autoPicked.insert(key(kind, disc)) } else { autoPicked.remove(key(kind, disc)) }
    }

    private var currentChoice: Choice { choice(tab, disc) }
    private func setChoice(_ value: Choice) { set(tab, tab == .disc ? disc : nil, value) }

    /// Candidates for the open tab; disc art for the chosen disc first.
    private var tabCandidates: [ArtCandidate] {
        let list = candidates.filter { $0.kind == tab }
        guard tab == .disc else { return list }
        return list.filter { $0.disc == disc } + list.filter { $0.disc != disc }
    }

    /// Everything that will change, in order: front, back, then discs.
    private var plan: [(kind: ArtworkKind, disc: Int?, choice: Choice)] {
        var result: [(kind: ArtworkKind, disc: Int?, choice: Choice)] = []
        if front != .keep && front != .remove { result.append((.front, nil, front)) }
        if onUseExtras != nil {
            if back != .keep { result.append((.back, nil, back)) }
            for number in discs.keys.sorted() where discs[number] != .keep { result.append((.disc, number, discs[number]!)) }
        }
        return result
    }

    private var summary: String {
        guard !plan.isEmpty else { return "Nothing will change yet. Pick images below, or choose files." }
        let parts = plan.map { item -> String in
            let what = item.kind == .disc ? "disc \(item.disc ?? 1)" : item.kind == .front ? "front" : "back"
            switch item.choice {
            case .keep: return what
            case .remove: return "remove \(what)"
            case .online(let candidate): return "\(what) from \(candidate.source.rawValue)"
            case .file(let name, _): return "\(what) from \(name)"
            }
        }
        return "Will save: " + parts.joined(separator: ", ") + "."
    }

    /// Fills in kinds the album doesn't have yet (and keeps updating Cover Flow's own
    /// picks as sources answer). The album's existing art is never replaced unasked.
    private func applyDefaults() {
        let picks = MusicLookupClient.defaultChoices(candidates)
        func pick(_ kind: ArtworkKind, _ disc: Int?, _ candidate: ArtCandidate?) {
            let mine = autoPicked.contains(key(kind, disc))
            guard choice(kind, disc) == .keep || mine else { return }
            if wants(kind), !hasCurrent(kind, disc), let candidate { set(kind, disc, .online(candidate), auto: true) }
            else if mine { set(kind, disc, .keep) }
        }
        pick(.front, nil, picks.front)
        guard onUseExtras != nil else { return }
        pick(.back, nil, picks.back)
        // Only the album's own discs are filled in; a single-disc album takes the first
        // disc image found even if a source lists it as another disc.
        for number in 1...discCount {
            pick(.disc, number, picks.discs[number] ?? (discCount == 1 ? picks.discs.keys.sorted().first.flatMap { picks.discs[$0] } : nil))
        }
        for number in discs.keys where number > discCount && autoPicked.contains(key(.disc, number)) { set(.disc, number, .keep) }
    }

    // MARK: Layout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Find Album Artwork").font(.title2.bold()); Spacer(); Button("Close") { cancelAll(); dismiss() } }
            HStack {
                TextField("Album title", text: $title).accessibilityLabel("Album title")
                TextField("Artist", text: $artist).accessibilityLabel("Album artist")
                Button("Search") { search() }.disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }.textFieldStyle(.roundedBorder).onSubmit { search() }
            filters
            HStack(alignment: .top, spacing: 18) {
                resultList
                chooser
            }
            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                if saving { ProgressView().controlSize(.small); Text("Saving…").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { cancelAll(); dismiss() }
                Button(plan.isEmpty ? "Done" : "Save Artwork") {
                    if plan.isEmpty { dismiss() } else { save() }
                }
                    .buttonStyle(.borderedProminent).disabled(busy)
            }
            Text("\(saveDescription) Album search by MusicBrainz.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 900, height: 680)
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
        .task(id: currentKey) { await loadCurrent(tab, tab == .disc ? disc : nil) }
        .task { if !searched { search(autoSelect: true) } }
        .onChange(of: sources) { _ in refreshSources() }
        .onChange(of: needsEditions) { _ in refreshSources() }
        .onChange(of: [wantFront, wantBack, wantDisc]) { _ in applyDefaults(); loadPreviews() }
        .onChange(of: tab) { _ in loadPreviews() }
        .onDisappear(perform: cancelAll)
    }

    @ViewBuilder private var filters: some View {
        HStack(spacing: 20) {
            if kinds.count > 1 {
                HStack(spacing: 10) {
                    Text("Look for").foregroundStyle(.secondary)
                    Toggle("Front", isOn: $wantFront)
                    Toggle("Back", isOn: $wantBack)
                    Toggle("Disc", isOn: $wantDisc)
                }
            }
            HStack(spacing: 10) {
                Text("Sources").foregroundStyle(.secondary)
                sourceToggle("Cover Art Archive", isOn: $useArchive, source: .coverArtArchive)
                sourceToggle("TheAudioDB", isOn: $useAudioDB, source: .theAudioDB)
                sourceToggle("fanart.tv", isOn: $useFanart, source: .fanartTV)
                    .disabled(fanartKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(fanartKey.isEmpty ? "Add a free fanart.tv API key in Settings › Back Covers & Disc Art to use it." : "Disc art and covers from fanart.tv")
            }
        }
        .font(.callout)
        #if os(macOS)
        .toggleStyle(.checkbox)
        #else
        .toggleStyle(.button)
        #endif
    }

    private func sourceToggle(_ name: String, isOn: Binding<Bool>, source: ArtSource) -> some View {
        HStack(spacing: 4) {
            Toggle(name, isOn: isOn)
            if loading.contains(source) { ProgressView().controlSize(.mini) }
            else if selected != nil, let count = found[source]?.filter({ wants($0.kind) }).count, sources.contains(source) {
                Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var resultList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if searching {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Searching MusicBrainz…").font(.caption).foregroundStyle(.secondary) }
            }
            List(results) { match in
                Button { load(match) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(match.title).fontWeight(.semibold)
                        Text(match.artist).font(.caption).foregroundStyle(.secondary)
                        Text(match.year).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(selected?.id == match.id ? Color.accentColor.opacity(0.22) : Color.clear)
                .disabled(saving)
            }
        }
        .frame(width: 230)
        .frame(minHeight: 300)
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
                ZStack {
                    ArtworkDownloadPreview(data: shownImage, circle: tab == .disc)
                    if currentChoice == .remove {
                        Image(systemName: "trash").font(.system(size: 34)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 220, height: 220)
                VStack(alignment: .leading, spacing: 8) {
                    if tab == .disc {
                        HStack {
                            if discSlots.count > 1 {
                                Picker("Disc", selection: $disc) {
                                    ForEach(discSlots, id: \.self) { Text("Disc \($0)").tag($0) }
                                }
                                .frame(width: 150)
                            }
                            Button(discSlots.count > 1 ? "Add Disc" : "Add Another Disc") {
                                addedDiscs = (discSlots.last ?? 1) + 1
                                disc = addedDiscs
                            }
                            .disabled(saving || discSlots.count >= 20)
                            .help("Add art for another disc, shown beside the first when you flip the cover.")
                        }
                    }
                    Text(choiceTitle).font(.headline)
                    Text(choiceDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Choose File…") { importing = true }
                        if currentChoice != .keep { Button("Keep Current") { setChoice(.keep) } }
                        if tab != .front, onRemoveExtras != nil, hasCurrent(tab, disc), currentChoice != .remove {
                            Button("Remove") { setChoice(.remove) }
                        }
                    }
                    .disabled(saving)
                }
                Spacer(minLength: 0)
            }
            candidateStrip
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var candidateStrip: some View {
        if selected == nil {
            Text(searching ? "" : "Pick an album on the left to see what’s available online.")
                .font(.caption).foregroundStyle(.secondary)
        } else if !wants(tab) {
            Text("\(tab.label) isn’t being looked for. Tick it under Look for.").font(.caption).foregroundStyle(.secondary)
        } else if sources.isEmpty {
            Text("Turn on at least one source.").font(.caption).foregroundStyle(.secondary)
        } else if tabCandidates.isEmpty && loading.isEmpty {
            Text("No \(tab.label.lowercased()) found in the sources that are on. Choose a file, or try another result.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if selected != nil && (!tabCandidates.isEmpty || hasCurrent(tab, disc)) {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    if hasCurrent(tab, disc) { currentTile }
                    ForEach(tabCandidates) { tile($0) }
                    if !loading.isEmpty && wants(tab) {
                        VStack { ProgressView().controlSize(.small) }.frame(width: 92, height: 92)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 140)
        }
    }

    private var shownImage: Data? {
        switch currentChoice {
        case .keep: return current[currentKey]
        case .remove: return nil
        case .online(let candidate): return previews[candidate.url]
        case .file(_, let data): return data
        }
    }

    private var choiceTitle: String {
        let what = tab == .disc ? "Disc \(disc)" : tab.label
        switch currentChoice {
        case .keep: return hasCurrent(tab, disc) ? "\(what): current" : "\(what): none yet"
        case .remove: return "\(what): will be removed"
        case .online(let candidate): return "\(what): \(candidate.source.rawValue)"
        case .file(let name, _): return "\(what): \(name)"
        }
    }

    private var choiceDetail: String {
        switch currentChoice {
        case .keep:
            return hasCurrent(tab, disc) ? "This is what the album has now. Pick an image below or choose a file to replace it."
                                         : "Pick an image below or choose a file."
        case .remove:
            return "It’s removed from the collection when you save."
        case .online(let candidate):
            var parts = [candidate.note].filter { !$0.isEmpty }
            if candidate.kind == .disc, candidate.disc != disc { parts.append("Listed for disc \(candidate.disc ?? 1)") }
            return parts.isEmpty ? "Replaces the current image when you save." : parts.joined(separator: " · ")
        case .file:
            return "Your image file. Replaces the current image when you save."
        }
    }

    private var currentTile: some View {
        let chosen = currentChoice == .keep
        return Button { setChoice(.keep) } label: {
            VStack(spacing: 3) {
                ArtworkDownloadPreview(data: current[currentKey], circle: tab == .disc)
                    .frame(width: 92, height: 92)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(chosen ? Color.accentColor : .clear, lineWidth: 3))
                Text("Current").font(.caption2.weight(chosen ? .semibold : .regular))
                Text(" ").font(.caption2)
            }
            .frame(width: 104).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(saving)
        .accessibilityLabel("Current \(tab.label.lowercased())")
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

    // MARK: Loading

    private func cancelAll() {
        searchWork?.cancel(); previewWork?.cancel(); saveWork?.cancel()
        sourceWork.values.forEach { $0.cancel() }
    }

    private func loadCurrent(_ kind: ArtworkKind, _ disc: Int?) async {
        let slot = key(kind, disc)
        guard current[slot] == nil, let url = currentImage?(kind, disc) else { return }
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        if let data { current[slot] = data }
    }

    /// Searches MusicBrainz. When opened, a result matching the album is picked at once.
    private func search(autoSelect: Bool = false) {
        guard !busy else { return }
        searched = true
        searchWork?.cancel()
        searching = true; message = nil
        let query = title, who = artist
        searchWork = Task {
            defer { searching = false }
            do {
                let matches = try await MusicLookupClient.shared.artwork(title: query, artist: who)
                try Task.checkCancellation()
                results = matches
                if autoSelect || selected == nil, let match = MusicLookupClient.pickMatch(matches, title: query, artist: who) ?? (matches.count == 1 ? matches.first : nil) {
                    load(match)
                }
            } catch is CancellationError {
            } catch MusicLookupError.noResults {
                results = []
                message = "MusicBrainz has no album called “\(query)” by \(who.isEmpty ? "that artist" : who). Try a shorter title, or choose files."
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }

    /// Shows the album's images from each source as soon as that source answers.
    /// Choices made from files are kept.
    private func load(_ match: ArtworkMatch) {
        guard !saving, selected?.id != match.id else { return }
        sourceWork.values.forEach { $0.cancel() }; sourceWork = [:]
        previewWork?.cancel()
        selected = match; found = [:]; loading = []; message = nil
        for kind in kinds {
            for number in (kind == .disc ? Array(discs.keys) : [0]) {
                let disc: Int? = kind == .disc ? number : nil
                if case .online = choice(kind, disc) { set(kind, disc, .keep) }
            }
        }
        autoPicked = []
        refreshSources()
    }

    /// Asks each source that's on (and not asked yet) for the selected album, in parallel.
    private func refreshSources() {
        guard let match = selected else { return }
        let fanart = fanartKey
        for source in ArtSource.allCases {
            let needed = sources.contains(source)
                && (found[source] == nil || (source == .coverArtArchive && needsEditions && !archiveHasEditions))
            guard needed, sourceWork[source] == nil else { continue }
            let editions = needsEditions
            loading.insert(source)
            sourceWork[source] = Task {
                let list = await MusicLookupClient.shared.artCandidates(match, source: source, editions: editions, fanartKey: fanart)
                guard !Task.isCancelled, selected?.id == match.id else { return }
                found[source] = list
                if source == .coverArtArchive { archiveHasEditions = editions }
                loading.remove(source)
                sourceWork[source] = nil
                applyDefaults()
                loadPreviews()
            }
        }
        applyDefaults()
        loadPreviews()
    }

    /// Previews for the open tab first, several at a time (each host has its own limit).
    private func loadPreviews() {
        let all = candidates.filter { previews[$0.url] == nil && !failedPreviews.contains($0.url) }
        let order = all.filter { $0.kind == tab } + all.filter { $0.kind != tab }
        guard !order.isEmpty else { return }
        previewWork?.cancel()
        previewWork = Task {
            await withTaskGroup(of: (URL, Data?).self) { group in
                for candidate in order {
                    group.addTask {
                        for url in [candidate.previewURL, candidate.url].compactMap({ $0 }) {
                            if Task.isCancelled { return (candidate.url, nil) }
                            if let bytes = try? await MusicLookupClient.shared.image(url), Self.isImage(bytes) { return (candidate.url, bytes) }
                        }
                        return (candidate.url, nil)
                    }
                }
                for await (url, data) in group {
                    if Task.isCancelled { return }
                    if let data { previews[url] = data } else { failedPreviews.insert(url) }
                }
            }
        }
    }

    private func save() {
        guard !busy, !plan.isEmpty else { return }
        saving = true; message = nil
        let items = plan
        let saveExtras = onUseExtras, removeExtras = onRemoveExtras
        saveWork = Task {
            defer { saving = false }
            do {
                // Downloads run together; files and removals need none.
                let downloads = await withTaskGroup(of: (Int, Data?).self) { group -> [Int: Data] in
                    for (i, item) in items.enumerated() {
                        guard case .online(let candidate) = item.choice else { continue }
                        group.addTask { (i, try? await MusicLookupClient.shared.image(candidate.url)) }
                    }
                    var result: [Int: Data] = [:]
                    for await (i, data) in group { if let data { result[i] = data } }
                    return result
                }
                try Task.checkCancellation()
                var frontData: Data?
                var extras: [ExtraImage] = []
                var removals: [(kind: AlbumImageKind, disc: Int?)] = []
                var failed: [String] = []
                for (i, item) in items.enumerated() {
                    let name = item.kind == .disc ? "disc \(item.disc ?? 1)" : item.kind.label.lowercased()
                    let data: Data
                    switch item.choice {
                    case .keep: continue
                    case .remove:
                        if let kind = item.kind.imageKind { removals.append((kind: kind, disc: item.disc)) }
                        continue
                    case .file(_, let bytes): data = bytes
                    case .online:
                        guard let bytes = downloads[i] else { failed.append(name); continue }
                        data = bytes
                    }
                    if item.kind == .front { frontData = data }
                    else if let kind = item.kind.imageKind { extras.append((kind: kind, disc: item.disc, data: data)) }
                }
                if let frontData { try await onUse(frontData) }
                if let removeExtras, !removals.isEmpty { await removeExtras(removals) }
                if let saveExtras, !extras.isEmpty { try await saveExtras(extras) }
                if failed.isEmpty { dismiss() }
                else { message = "Couldn’t download the \(failed.joined(separator: ", ")). Everything else was saved; try again or choose another image." }
            }
            catch is CancellationError { }
            catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }

    nonisolated static func isImage(_ data: Data) -> Bool {
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
