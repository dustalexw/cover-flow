import SwiftUI
import AppKit

struct GridView: View {
    let albums: [Album]
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var state: AppState

    @State private var frames: [UUID: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeEnd: CGPoint?
    @State private var dragBase = Set<UUID>()
    @State private var suppressClick = false
    @FocusState private var focused: Bool
    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 20, alignment: .top)]

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(albums) { album in
                            GridCell(album: album, isPlayingAlbum: album.id == player.currentAlbumID,
                                     isSelected: state.selection.ids.contains(album.id)) {
                                guard !suppressClick else { return }
                                focused = true
                                let flags = NSApp.currentEvent?.modifierFlags ?? []
                                state.selection.select(album.id, ordered: albums.map(\.id),
                                                       extend: flags.contains(.shift), toggle: flags.contains(.command))
                                state.browsedAlbumID = album.id
                                if (NSApp.currentEvent?.clickCount ?? 0) >= 2 && !flags.contains(.shift) && !flags.contains(.command) {
                                    state.detailAlbum = IDRef(id: album.id)
                                }
                            }
                            .id(album.id)
                            .background(GeometryReader { cell in
                                Color.clear.preference(key: AlbumFramesKey.self,
                                                       value: [album.id: cell.frame(in: .named("albumGrid"))])
                            })
                        }
                    }
                    .padding(20)
                    .frame(minHeight: geometry.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .coordinateSpace(name: "albumGrid")
                    .onPreferenceChange(AlbumFramesKey.self) { frames = $0 }
                    .overlay(alignment: .topLeading) {
                        if let start = marqueeStart, let end = marqueeEnd {
                            let rect = selectionRect(start, end)
                            Rectangle().fill(Color.accentColor.opacity(0.12))
                                .overlay(Rectangle().stroke(Color.accentColor.opacity(0.8), lineWidth: 1))
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("albumGrid"))
                        .onChanged { value in
                            if marqueeStart == nil {
                                focused = true
                                marqueeStart = value.startLocation
                                let flags = NSApp.currentEvent?.modifierFlags ?? []
                                dragBase = flags.contains(.shift) || flags.contains(.command) ? state.selection.ids : []
                            }
                            suppressClick = true
                            marqueeEnd = value.location
                            let rect = selectionRect(value.startLocation, value.location)
                            let hits = Set(frames.filter { rect.intersects($0.value) }.map(\.key))
                            state.selection.marquee(intersecting: hits, addingTo: dragBase)
                        }
                        .onEnded { _ in
                            if let first = albums.first(where: { state.selection.ids.contains($0.id) }) {
                                state.browsedAlbumID = first.id
                                state.selection.finishMarquee(ordered: albums.map(\.id))
                            }
                            marqueeStart = nil; marqueeEnd = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { suppressClick = false }
                        })
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
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.escape) { state.selection.clear(); return .handled }
        .onKeyPress(.return) {
            if let id = state.browsedAlbumID { state.detailAlbum = IDRef(id: id) }
            return .handled
        }
        .onKeyPress(phases: .down) { event in
            guard event.modifiers.contains(.command), event.characters.lowercased() == "a" else { return .ignored }
            state.selection.selectAll(albums.map(\.id))
            return .handled
        }
    }

    private func selectionRect(_ start: CGPoint, _ end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

private struct AlbumFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct GridCell: View {
    let album: Album
    let isPlayingAlbum: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onSelect) {
                ArtworkView(album: album, pointSize: 360, cornerRadius: 4)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(scheme == .dark ? (hover ? 0.6 : 0.4) : 0.18), radius: hover ? 16 : 8, y: hover ? 9 : 5)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel("\(album.title) by \(album.artist)\(isPlayingAlbum ? ", now playing" : "")")
            .accessibilityHint("Click to select. Shift-click selects a range. Double-click shows tracks.")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAction(named: "Show Tracks") { state.detailAlbum = IDRef(id: album.id) }
            .overlay(alignment: .topTrailing) { SelectedAlbumBadge(selected: isSelected) }
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
        .padding(7)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
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

    private var selectionAlbums: [Album] {
        guard state.selection.ids.contains(album.id), state.selection.ids.count > 1 else { return [album] }
        return library.visibleAlbums(sort: state.sortOrder, search: state.searchText).filter { state.selection.ids.contains($0.id) }
    }
    private var selectionTracks: [UUID] { selectionAlbums.flatMap(\.trackIDs) }

    var body: some View {
        Button(selectionAlbums.count > 1 ? "Play \(selectionAlbums.count) Albums" : "Play") {
            player.setQueue(selectionTracks, startIndex: 0, autoplay: true)
        }
        Button("Shuffle") {
            player.setQueue(selectionTracks, startIndex: 0, autoplay: true, shuffled: true)
        }
        Button("Play Next") { player.playNext(selectionTracks) }
        Button("Add to Queue") { player.addToQueue(selectionTracks) }
        Divider()
        Button("Show Tracks") { state.detailAlbum = IDRef(id: album.id) }
        Button("Edit Album Info…") { state.editAlbum = IDRef(id: album.id) }
        Button("Replace Artwork…") { library.chooseReplacementArtwork(for: album.id) }
        Divider()
        Button(selectionAlbums.count > 1 ? "Remove \(selectionAlbums.count) Albums…" : "Remove from Collection…", role: .destructive) {
            if selectionAlbums.count > 1 { state.selectedAlbumRemoval = selectionAlbums.map(\.id) }
            else { state.confirmRemoval = IDRef(id: album.id) }
        }
    }
}
