import SwiftUI

struct GridView: View {
    let albums: [Album]
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var state: AppState

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 230), spacing: 28, alignment: .top)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 34) {
                    ForEach(albums) { album in
                        GridCell(album: album,
                                 isSelected: album.id == state.browsedAlbumID,
                                 isPlayingAlbum: album.id == player.currentAlbumID)
                            .id(album.id)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 30)
            }
            .onAppear {
                if let id = state.browsedAlbumID { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: state.revealRequest) {
                guard let req = state.revealRequest else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(req.id, anchor: .center) }
            }
        }
    }
}

struct GridCell: View {
    let album: Album
    let isSelected: Bool
    let isPlayingAlbum: Bool
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                state.browsedAlbumID = album.id
                state.detailAlbum = IDRef(id: album.id)
            } label: {
                ArtworkView(album: album, pointSize: 230, cornerRadius: 4)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(scheme == .dark ? (hover ? 0.6 : 0.4) : 0.18), radius: hover ? 16 : 8, y: hover ? 9 : 5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Palette.accent(scheme), lineWidth: 2.5)
                            .padding(-5)
                            .opacity(focused ? 1 : (isSelected ? 0.35 : 0))
                    )
            }
            .buttonStyle(.plain)
            .focused($focused)
            .accessibilityLabel("\(album.title) by \(album.artist)\(isPlayingAlbum ? ", now playing" : "")")
            .accessibilityHint("Shows the track list")
            .overlay(alignment: .bottomTrailing) {
                if hover || isPlayingAlbum {
                    Button {
                        if isPlayingAlbum { player.togglePlayPause() } else { player.play(albumID: album.id) }
                    } label: {
                        Image(systemName: isPlayingAlbum && player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(IconButtonStyle(size: 34, prominent: true))
                    .shadow(radius: 6)
                    .padding(10)
                    .accessibilityLabel(isPlayingAlbum && player.isPlaying ? "Pause \(album.title)" : "Play \(album.title)")
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if isPlayingAlbum {
                    NowPlayingBars(playing: player.isPlaying, color: .white, height: 11)
                        .padding(6)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                        .padding(8)
                }
            }
            .scaleEffect(hover ? 1.02 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(album.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if album.isDemo { DemoChip() }
                }
                Text(album.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .contextMenu { AlbumContextMenu(album: album) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(album.title) by \(album.artist)\(isPlayingAlbum ? ", now playing" : "")")
    }
}

struct AlbumContextMenu: View {
    let album: Album
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Button("Play") { player.play(albumID: album.id) }
        Button("Shuffle") { player.play(albumID: album.id, shuffled: true) }
        Button("Play Next") { player.playNext(album.trackIDs) }
        Button("Add to Queue") { player.addToQueue(album.trackIDs) }
        Divider()
        Button("Show Tracks") { state.detailAlbum = IDRef(id: album.id) }
        Button("Edit Album Info…") { state.editAlbum = IDRef(id: album.id) }
        Button("Replace Artwork…") { library.chooseReplacementArtwork(for: album.id) }
        Divider()
        Button("Remove from Collection…", role: .destructive) { state.confirmRemoval = IDRef(id: album.id) }
    }
}
