import SwiftUI
import AppKit

struct AlbumDetailView: View {
    let albumID: UUID
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let album = library.album(albumID) {
                content(album)
            } else {
                VStack(spacing: 12) {
                    Text("This album is no longer in your collection.").foregroundStyle(.secondary)
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .frame(width: 420, height: 200)
            }
        }
        .background(TintBackground(tintHex: library.album(albumID)?.tintHex))
        .sheet(item: $state.editAlbum) { ref in
            AlbumEditView(albumID: ref.id)
                .environmentObject(library)
        }
        .modifier(RemoveAlbumConfirmation(active: true))
    }

    private func content(_ album: Album) -> some View {
        let tracks = library.tracks(of: album)
        let discs = Set(tracks.map { $0.discNumber ?? 1 })
        let multiDisc = discs.count > 1
        return HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 16) {
                ArtworkView(album: album, pointSize: 290, cornerRadius: 4)
                    .frame(width: 290, height: 290)
                    .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if album.isDemo { DemoChip() }
                        if album.missingMetadata {
                            Label("Some info was guessed from file names", systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(album.title)
                        .font(Typography.albumTitle(24))
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Text(album.artist)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(detailLine(album, tracks: tracks))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 290, alignment: .leading)
                HStack(spacing: 8) {
                    Button {
                        player.play(albumID: album.id, shuffled: false)
                    } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(PillButtonStyle(prominent: true))
                    Button {
                        player.play(albumID: album.id, shuffled: true)
                    } label: { Label("Shuffle", systemImage: "shuffle") }
                        .buttonStyle(PillButtonStyle())
                    Menu {
                        Button("Play Next") { player.playNext(album.trackIDs) }
                        Button("Add to Queue") { player.addToQueue(album.trackIDs) }
                        Divider()
                        Button("Edit Album Info…") { state.editAlbum = IDRef(id: album.id) }
                        Button("Replace Artwork…") { library.chooseReplacementArtwork(for: album.id) }
                        if album.hasArtwork && !album.isDemo {
                            Button("Remove Artwork") { library.removeArtwork(album.id) }
                        }
                        Divider()
                        Button("Remove from Collection…", role: .destructive) {
                            state.confirmRemoval = IDRef(id: album.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 34, height: 30)
                    .background(Circle().fill(Palette.raised(scheme)))
                    .accessibilityLabel("More actions")
                }
                Spacer(minLength: 0)
            }
            .frame(width: 290)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Tracks")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Button {
                        state.editAlbum = IDRef(id: album.id)
                    } label: { Label("Edit Info", systemImage: "pencil") }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(PillButtonStyle())
                        .padding(.leading, 8)
                }
                .padding(.bottom, 10)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                            let disc = track.discNumber ?? 1
                            if multiDisc && (i == 0 || (tracks[i - 1].discNumber ?? 1) != disc) {
                                Text("Disc \(disc)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, i == 0 ? 2 : 14)
                                    .padding(.bottom, 4)
                                    .padding(.leading, 8)
                            }
                            TrackRow(track: track, position: i + 1, album: album)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(28)
        .frame(width: 860, height: 600)
    }

    private func detailLine(_ album: Album, tracks: [Track]) -> String {
        var parts: [String] = []
        if let y = album.year { parts.append(String(y)) }
        if let g = album.genre { parts.append(g) }
        parts.append(tracks.count == 1 ? "1 track" : "\(tracks.count) tracks")
        parts.append(formatLongDuration(tracks.reduce(0) { $0 + $1.duration }))
        return parts.joined(separator: " · ")
    }
}

struct TrackRow: View {
    let track: Track
    let position: Int
    let album: Album
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false
    @State private var exists = true

    var body: some View {
        let isCurrent = player.currentTrackID == track.id
        Button {
            if isCurrent { player.togglePlayPause() } else { player.play(albumID: album.id, startAt: track.id) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if isCurrent {
                        NowPlayingBars(playing: player.isPlaying, color: Palette.accent(scheme), height: 11)
                    } else if hover {
                        Image(systemName: "play.fill").font(.system(size: 11))
                    } else {
                        Text(track.trackNumber.map(String.init) ?? "–")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Palette.accent(scheme) : Color.primary)
                        .lineLimit(1)
                    if track.artist != album.artist && album.artist != "" {
                        Text(track.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !exists {
                    Label("File missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .help(track.fileURL.path)
                }
                Text(formatTime(track.duration))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hover ? Palette.raisedHover(scheme) : (isCurrent ? Palette.raised(scheme) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Play") { player.play(albumID: album.id, startAt: track.id) }
            Button("Play Next") { player.playNext([track.id]) }
            Button("Add to Queue") { player.addToQueue([track.id]) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([track.fileURL]) }
        }
        .task { exists = library.fileExists(track) }
        .accessibilityLabel("Track \(track.trackNumber ?? position), \(track.title), \(formatTime(track.duration))\(isCurrent ? ", now playing" : "")\(exists ? "" : ", file missing")")
        .accessibilityHint(isCurrent ? "Play or pause" : "Play from this track")
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
            Text("Changes are saved to Cover Flow’s library only — your audio files are not modified.")
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
        .frame(width: 620, height: 600)
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
