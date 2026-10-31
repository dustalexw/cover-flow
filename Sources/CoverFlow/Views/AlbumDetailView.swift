import SwiftUI
import AppKit

struct AlbumDetailView: View {
    let albumID: UUID
    let style: AlbumPanelStyle
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var downloadArtwork = false
    @State private var downloadKind: ArtworkKind = .front
    @State private var trackToRemove: Track?
    @State private var confirmingTrackRemoval = false
    @State private var trackToEdit: IDRef?

    var body: some View {
        Group {
            if let album = library.album(albumID) {
                content(album, colors: style.colors)
            } else {
                VStack(spacing: 12) {
                    Text("This album is no longer in your collection.").foregroundStyle(.secondary)
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .frame(width: 420, height: 200)
            }
        }
        .background(AlbumPanelEvents(enabled: state.editAlbum == nil && state.appearanceAlbum == nil && state.confirmRemoval == nil && !confirmingTrackRemoval && !downloadArtwork && trackToEdit == nil,
                                     onDismiss: { dismiss() }, onTogglePlayback: { player.togglePlayPause() }))
        .sheet(item: $state.editAlbum) { ref in
            AlbumEditView(albumID: ref.id).environmentObject(library)
        }
        .sheet(item: $trackToEdit) { ref in
            TrackEditView(trackID: ref.id).environmentObject(library)
        }
        .sheet(item: $state.appearanceAlbum) { ref in
            AlbumAppearanceView(albumID: ref.id).environmentObject(library)
        }
        .sheet(isPresented: $downloadArtwork) {
            if let album = library.album(albumID) {
                ArtworkDownloadView(album: album, saveDescription: "A new front cover is also embedded in supported audio files. Back covers and disc art are kept in the collection and shown when you flip the cover in Cover Flow.",
                                    discCount: library.discNumbers(of: album).max() ?? 1, initialKind: downloadKind, onUse: { data in
                    guard library.album(albumID) != nil else { throw MusicLookupError.itemRemoved }
                    library.replaceArtwork(albumID, with: data)
                }, onUseExtras: { images in
                    guard library.album(albumID) != nil else { throw MusicLookupError.itemRemoved }
                    await library.replaceExtraImages(albumID, with: images)
                })
            }
        }
        .modifier(RemoveAlbumConfirmation(active: true))
        .alert("Remove Track from Collection?", isPresented: $confirmingTrackRemoval, presenting: trackToRemove) { track in
            Button("Remove Track", role: .destructive) {
                library.removeTracks([track.id])
                if library.album(albumID) == nil { dismiss() }
            }
            Button("Cancel", role: .cancel) { }
        } message: { track in
            Text("“\(track.title)” will be removed from this album and the playback queue. " + (track.isDemo
                ? "Its generated demo audio will be deleted."
                : "Your original audio file will stay on disk."))
        }
    }

    private func content(_ album: Album, colors: AlbumDetailPalette) -> some View {
        let tracks = library.tracks(of: album)
        let multiDisc = Set(tracks.map { $0.discNumber ?? 1 }).count > 1
        let columns = trackColumns(tracks)
        let height = max(540, min(660, CGFloat(columns.map(\.count).max() ?? 0) * 32 + 220))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(album.title)
                        .font(.custom("Helvetica Neue", size: 28).weight(.bold))
                        .foregroundStyle(colors.foreground.color)
                        .lineLimit(2).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(album.artist).font(.custom("Helvetica Neue", size: 17))
                        if album.isDemo { DemoChip() }
                    }
                    .foregroundStyle(colors.accent.color)
                    Text(metadataLine(album))
                        .font(.custom("Helvetica Neue", size: 12))
                        .foregroundStyle(colors.secondary.color)
                    if album.missingMetadata {
                        Label("Some info was guessed from file names", systemImage: "exclamationmark.circle")
                            .font(.custom("Helvetica Neue", size: 11)).foregroundStyle(colors.secondary.color)
                    }
                }
                Spacer(minLength: 12)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 21))
                        .foregroundStyle(colors.secondary.color)
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                .accessibilityLabel("Done").help("Close album tracks (Esc)")
            }
            .padding(.bottom, 19)

            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 14) {
                    albumControls(album, colors: colors)
                    Rectangle().fill(colors.foreground.color.opacity(0.18)).frame(height: 1)
                    ScrollView {
                        HStack(alignment: .top, spacing: 22) {
                            ForEach(columns.indices, id: \.self) { column in
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(columns[column], id: \.id) { track in
                                        let index = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
                                        let disc = track.discNumber ?? 1
                                        if multiDisc && (track.id == columns[column].first?.id || index == 0 || (tracks[index - 1].discNumber ?? 1) != disc) {
                                            Text("Disc \(disc)")
                                                .font(.custom("Helvetica Neue", size: 11).weight(.bold))
                                                .foregroundStyle(colors.secondary.color)
                                                .padding(.top, track.id == columns[column].first?.id ? 0 : 14)
                                                .padding(.bottom, 5).padding(.leading, 8)
                                        }
                                        TrackRow(track: track, position: index + 1, album: album, colors: colors, onRemove: { track in
                                            trackToRemove = track
                                            confirmingTrackRemoval = true
                                        }, onEdit: { track in
                                            trackToEdit = IDRef(id: track.id)
                                        })
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    Text(summaryLine(tracks))
                        .font(.custom("Helvetica Neue", size: 11))
                        .foregroundStyle(colors.secondary.color)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                ArtworkView(album: album, pointSize: 340, cornerRadius: 0)
                    .frame(width: 340, height: 340)
                    .overlay(Rectangle().strokeBorder(colors.foreground.color.opacity(0.10)))
                    .shadow(color: .black.opacity(0.24), radius: 10, x: 0, y: 5)
                    .padding(.top, 2)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(30)
        .frame(width: 1080, height: height, alignment: .topLeading)
        .background(AlbumSceneBackground(style: style).ignoresSafeArea())
        .environment(\.colorScheme, colors.foreground.luminance < 0.5 ? .light : .dark)
    }

    private func albumControls(_ album: Album, colors: AlbumDetailPalette) -> some View {
        HStack(spacing: 8) {
            Button { player.play(albumID: album.id, shuffled: false) } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(AlbumDetailButtonStyle(palette: colors))
            Button { player.play(albumID: album.id, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                .buttonStyle(AlbumDetailButtonStyle(palette: colors))
            Menu {
                Button("Play Next") { player.playNext(album.trackIDs) }
                Button("Add to Queue") { player.addToQueue(album.trackIDs) }
                Divider()
                Button("Edit Album Info…") { state.editAlbum = IDRef(id: album.id) }
                Button("Colors & Scene…") { state.appearanceAlbum = IDRef(id: album.id) }
                Button("Find Artwork Online…") { downloadKind = .front; downloadArtwork = true }
                if !album.isDemo {
                    Button("Find Back Cover & Disc Art Online…") { downloadKind = library.album(album.id)?.backImage == nil ? .back : .disc; downloadArtwork = true }
                    Button("Fill In Missing Back & Disc Art Automatically") { library.findExtraArt([album.id]) }
                        .disabled(library.importProgress != nil)
                }
                CustomArtworkMenu(album: album)
                if album.hasArtwork && !album.isDemo { Button("Remove Artwork") { library.removeArtwork(album.id) } }
                if album.hasExtraImages { Button("Remove Back & Disc Art") { library.removeExtraImages(album.id) } }
                Divider()
                Button("Remove from Collection…", role: .destructive) { state.confirmRemoval = IDRef(id: album.id) }
            } label: {
                Text(" ").frame(width: 18, height: 14)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width: 30, height: 26)
            .background(colors.foreground.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            // AppKit's borderless Menu drops Shape-only labels. Draw the dots
            // above the native menu instead, without intercepting its clicks.
            .overlay {
                HStack(spacing: 3) {
                    ForEach(0..<3) { _ in Circle().fill(colors.foreground.color).frame(width: 3, height: 3) }
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            .accessibilityLabel("More actions")
            Spacer()
            Button { state.appearanceAlbum = IDRef(id: album.id) } label: {
                Label("Colors & Scene", systemImage: "paintpalette")
            }
                .buttonStyle(.plain).font(.custom("Helvetica Neue", size: 11))
                .foregroundStyle(colors.secondary.color)
        }
    }

    private func trackColumns(_ tracks: [Track]) -> [[Track]] {
        guard tracks.count > 9, !tracks.contains(where: { TrackTitleLayout.needsWideColumn($0.title) }) else { return [tracks] }
        let midpoint = (tracks.count + 1) / 2
        // Prefer a disc boundary near the middle, without creating an unbalanced list.
        let boundaries = (1..<tracks.count).filter {
            (tracks[$0].discNumber ?? 1) != (tracks[$0 - 1].discNumber ?? 1)
                && abs($0 - midpoint) <= max(2, tracks.count / 6)
        }
        let split = boundaries.min { abs($0 - midpoint) < abs($1 - midpoint) } ?? midpoint
        return [Array(tracks[..<split]), Array(tracks[split...])]
    }

    private func metadataLine(_ album: Album) -> String {
        [album.genre?.nonEmpty, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }

    private func summaryLine(_ tracks: [Track]) -> String {
        "\(tracks.count == 1 ? "1 song" : "\(tracks.count) songs"), \(formatLongDuration(tracks.reduce(0) { $0 + $1.duration }))"
    }
}

struct TrackRow: View {
    let track: Track
    let position: Int
    let album: Album
    let colors: AlbumDetailPalette
    var onRemove: (Track) -> Void
    var onEdit: (Track) -> Void = { _ in }
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @State private var hover = false
    @State private var exists = true

    var body: some View {
        let isCurrent = player.currentTrackID == track.id
        Button {
            if isCurrent { player.togglePlayPause() } else { player.play(albumID: album.id, startAt: track.id) }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    if isCurrent {
                        NowPlayingBars(playing: player.isPlaying, color: colors.accent.color, height: 11)
                    } else if hover {
                        Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(colors.accent.color)
                    } else {
                        Text(track.trackNumber.map(String.init) ?? String(position))
                            .font(.custom("Helvetica Neue", size: 12).monospacedDigit())
                            .foregroundStyle(colors.secondary.color)
                    }
                }
                .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.custom("Helvetica Neue", size: 13).weight(isCurrent ? .medium : .regular))
                        .foregroundStyle(isCurrent ? colors.accent.color : colors.foreground.color)
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                        .help(track.title)
                    if track.artist != album.artist && !album.artist.isEmpty {
                        Text(track.artist).font(.custom("Helvetica Neue", size: 11))
                            .foregroundStyle(colors.secondary.color).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !exists {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(colors.foreground.color)
                        .help("File missing: \(track.fileURL.path)")
                }
                Text(formatTime(track.duration))
                    .font(.custom("Helvetica Neue", size: 12).monospacedDigit())
                    .foregroundStyle(colors.secondary.color)
                    .frame(width: 42, alignment: .trailing)
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .frame(minHeight: 30)
            .background(colors.foreground.color.opacity(hover ? 0.10 : (isCurrent ? 0.07 : 0)), in: RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Play") { player.play(albumID: album.id, startAt: track.id) }
            Button("Play Next") { player.playNext([track.id]) }
            Button("Add to Queue") { player.addToQueue([track.id]) }
            Divider()
            Button("Edit Track Info…") { onEdit(track) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([track.fileURL]) }
            Divider()
            Button("Remove from Collection…", role: .destructive) { onRemove(track) }
        }
        .task(id: track.fileURL) { exists = library.fileExists(track) }
        .accessibilityLabel("Track \(track.trackNumber ?? position), \(track.title), \(formatTime(track.duration))\(isCurrent ? ", now playing" : "")\(exists ? "" : ", file missing")")
        .accessibilityHint(isCurrent ? "Play or pause" : "Play from this track")
    }
}

/// Edit Track Info: one track's title, artist, numbers, year and genre (library only).
struct TrackEditView: View {
    let trackID: UUID
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var trackNumber = ""
    @State private var discNumber = ""
    @State private var year = ""
    @State private var genre = ""
    @State private var loaded = false
    @AppStorage(LibraryStore.writeEditsDefaultsKey) private var writeToFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Track Info")
                .font(Typography.albumTitle(20))
            if let track = library.track(trackID) {
                HStack(alignment: .top, spacing: 18) {
                    if let album = library.album(library.albumID(forTrack: trackID)) {
                        ArtworkView(album: album, pointSize: 96)
                            .frame(width: 96, height: 96)
                            .accessibilityHidden(true)
                    }
                    Form {
                        TextField("Title", text: $title)
                        TextField("Artist", text: $artist)
                        LabeledContent("Track") {
                            HStack(spacing: 8) {
                                TextField("", text: $trackNumber).frame(width: 52).accessibilityLabel("Track number")
                                Text("Disc").foregroundStyle(.secondary)
                                TextField("", text: $discNumber).frame(width: 52).accessibilityLabel("Disc number")
                            }
                        }
                        LabeledContent("Year") {
                            TextField("", text: $year).frame(width: 80).accessibilityLabel("Year")
                        }
                        TextField("Genre", text: $genre)
                    }
                    .formStyle(.columns)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let album = library.album(library.albumID(forTrack: trackID)) {
                        Text("Album: \(album.title)")
                    }
                    Text("Length: \(formatTime(track.duration)) · \(track.fileURL.pathExtension.uppercased())")
                    Text(track.fileURL.path)
                        .lineLimit(1).truncationMode(.middle)
                        .help(track.fileURL.path)
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Toggle("Also save changes to the audio file", isOn: $writeToFiles)
                    .disabled(track.isDemo)
                Text((writeToFiles && !track.isDemo
                      ? "Changes are saved to Cover Flow’s library and written into the file’s tags."
                      : "Changes are saved to Cover Flow’s library; the audio file isn’t modified.")
                     + " To change the album or its artwork, use Edit Album Info.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This track is no longer in your collection.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    library.updateTrack(trackID, title: title, artist: artist, trackNumber: trackNumber,
                                        discNumber: discNumber, year: year, genre: genre)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(library.track(trackID) == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded, let track = library.track(trackID) else { return }
        loaded = true
        title = track.title
        artist = track.artist
        trackNumber = track.trackNumber.map(String.init) ?? ""
        discNumber = track.discNumber.map(String.init) ?? ""
        year = track.year.map(String.init) ?? ""
        genre = track.genre ?? ""
    }
}

struct AlbumEditView: View {
    let albumID: UUID
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var year = ""
    @State private var genre = ""
    @State private var edits: [LibraryStore.TrackEdit] = []
    @State private var loaded = false
    @AppStorage(LibraryStore.writeEditsDefaultsKey) private var writeToFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Album Info")
                .font(Typography.albumTitle(20))
            HStack(alignment: .top, spacing: 18) {
                if let album = library.album(albumID) {
                    VStack(spacing: 8) {
                        ArtworkView(album: album, pointSize: 140)
                            .frame(width: 140, height: 140)
                        Button("Replace Artwork…") { library.chooseReplacementArtwork(for: albumID) }
                            .controlSize(.small)
                    }
                }
                Form {
                    TextField("Album", text: $title)
                    TextField("Artist", text: $artist)
                    TextField("Year", text: $year)
                    TextField("Genre", text: $genre)
                }
                .formStyle(.columns)
            }
            Text("Tracks")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    HStack {
                        Text("Disc").frame(width: 44, alignment: .leading)
                        Text("No.").frame(width: 44, alignment: .leading)
                        Text("Title")
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach($edits) { $edit in
                        HStack {
                            TextField("", text: $edit.discNumber).frame(width: 44).accessibilityLabel("Disc number")
                            TextField("", text: $edit.trackNumber).frame(width: 44).accessibilityLabel("Track number")
                            TextField("", text: $edit.title).accessibilityLabel("Track title")
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .frame(minHeight: 160)
            Toggle("Also save changes to the audio files", isOn: $writeToFiles)
                .disabled(library.album(albumID)?.isDemo ?? true)
            Text(writeToFiles && library.album(albumID)?.isDemo == false
                 ? "Edits are saved to Cover Flow’s library and written into the album’s audio files. Replacing artwork also embeds the cover."
                 : "Text edits are saved to Cover Flow’s library. Replacing artwork also embeds the cover in the album’s audio files.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    library.updateAlbum(albumID, title: title, artist: artist, year: year, genre: genre, trackEdits: edits)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 630)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded, let album = library.album(albumID) else { return }
        loaded = true
        title = album.title
        artist = album.artist
        year = album.year.map(String.init) ?? ""
        genre = album.genre ?? ""
        edits = library.tracks(of: album).map {
            LibraryStore.TrackEdit(id: $0.id, title: $0.title,
                                   trackNumber: $0.trackNumber.map(String.init) ?? "",
                                   discNumber: $0.discNumber.map(String.init) ?? "")
        }
    }
}

/// Choose any kind of artwork from an image file: front cover, back cover, or disc art.
struct CustomArtworkMenu: View {
    let album: Album
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Menu("Choose Artwork from File") {
            Button("Front Cover…") { library.chooseReplacementArtwork(for: album.id) }
            Button("Back Cover…") { library.chooseExtraArtwork(for: album.id, kind: .back, disc: nil) }
            let discs = library.discNumbers(of: album).sorted()
            if discs.count > 1 {
                ForEach(discs, id: \.self) { number in
                    Button("Disc \(number) Art…") { library.chooseExtraArtwork(for: album.id, kind: .disc, disc: number) }
                }
            } else {
                Button("Disc Art…") { library.chooseExtraArtwork(for: album.id, kind: .disc, disc: discs.first ?? 1) }
            }
        }
    }
}
