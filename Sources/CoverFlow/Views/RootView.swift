import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var albumView: AlbumViewController
    @Environment(\.colorScheme) private var scheme
    @State private var dropTargeted = false
    @State private var preparedDetail: AlbumDetailPresentation?

    private struct AlbumDetailPresentation: Identifiable {
        let id: UUID
        let colors: AlbumDetailPalette
    }

    private var detailArtworkKey: String? {
        guard let album = library.album(state.detailAlbum?.id) else { return nil }
        // Include metadata for the placeholder palette when there is no artwork.
        return album.hasArtwork ? album.artworkKey : "\(album.artworkKey):\(album.title):\(album.artist):\(album.tintHex ?? "")"
    }

    var body: some View {
        let albums = library.visibleAlbums(sort: state.sortOrder, search: state.searchText)
        let browsed = library.album(state.browsedAlbumID)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Group {
                    if library.albums.isEmpty {
                        EmptyCollectionView()
                    } else if albums.isEmpty {
                        NoResultsView(query: state.searchText)
                    } else if state.browseMode == .coverFlow {
                        CoverFlowView(albums: albums)
                    } else {
                        GridView(albums: albums)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                StatusBanners()
                    .padding(.top, 10)
                    .padding(.horizontal, 20)
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Palette.accent(scheme), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(Palette.base(scheme).opacity(0.55).clipShape(RoundedRectangle(cornerRadius: 14)))
                        .overlay(
                            Label("Drop to add to your collection", systemImage: "square.and.arrow.down")
                                .font(.system(size: 16, weight: .semibold))
                        )
                        .padding(18)
                        .allowsHitTesting(false)
                }
            }
            if !state.selection.ids.isEmpty { AlbumSelectionBar(albums: albums) }
            NowPlayingBar()
        }
        .background(TintBackground(tintHex: (browsed ?? player.currentAlbum)?.tintHex))
        .frame(minWidth: 720, minHeight: 540)
        .navigationTitle("Cover Flow")
        .navigationSubtitle(subtitle(visible: albums.count))
        .toolbar { toolbar }
        .inspector(isPresented: $state.showQueue) {
            QueueView()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .task(id: detailArtworkKey) {
            guard let album = library.album(state.detailAlbum?.id) else { preparedDetail = nil; return }
            let colors = await library.artwork.albumDetailPalette(album)
            guard !Task.isCancelled, state.detailAlbum?.id == album.id else { return }
            // Never present a temporary palette: the sheet's first frame has its final colors.
            preparedDetail = AlbumDetailPresentation(id: album.id, colors: colors)
        }
        .sheet(item: Binding(get: { preparedDetail }, set: { value in
            preparedDetail = value
            if value == nil { state.detailAlbum = nil }
        })) { ref in
            AlbumDetailView(albumID: ref.id, colors: ref.colors)
                .environmentObject(library).environmentObject(player).environmentObject(state)
        }
        .sheet(item: Binding(get: { state.detailAlbum == nil ? state.editAlbum : nil },
                             set: { state.editAlbum = $0 })) { ref in
            AlbumEditView(albumID: ref.id)
                .environmentObject(library)
        }
        .modifier(RemoveAlbumConfirmation(active: state.detailAlbum == nil))
        .dropDestination(for: URL.self) { urls, _ in
            library.importURLs(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onChange(of: albums.map(\.id)) { state.selection.retainVisible(albums.map(\.id)) }
        .confirmationDialog("Remove \(state.selectedAlbumRemoval?.count ?? 0) albums from your collection?",
                            isPresented: Binding(get: { state.selectedAlbumRemoval != nil },
                                                 set: { if !$0 { state.selectedAlbumRemoval = nil } })) {
            Button("Remove Selected Albums", role: .destructive) {
                library.removeAlbums(Set(state.selectedAlbumRemoval ?? []))
                state.selectedAlbumRemoval = nil
                state.selection.clear()
            }
            Button("Cancel", role: .cancel) { state.selectedAlbumRemoval = nil }
        } message: {
            Text("Your imported audio files stay on disk. Generated demo audio belonging to these albums will be deleted.")
        }
        .preferredColorScheme(state.colorScheme)
    }

    private func subtitle(visible: Int) -> String {
        let total = library.albums.count
        if total == 0 { return "" }
        if !state.searchText.isEmpty { return "\(visible) of \(total) albums" }
        return total == 1 ? "1 album" : "\(total) albums"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Browse", selection: $state.browseMode) {
                Image(systemName: "rectangle.stack").accessibilityLabel("Cover Flow").tag(BrowseMode.coverFlow)
                Image(systemName: "square.grid.3x3").accessibilityLabel("Grid").tag(BrowseMode.grid)
            }
            .pickerStyle(.segmented)
            .help("Cover Flow (⌘1) or Grid (⌘2)")
        }
        ToolbarItem(placement: .principal) {
            if let p = library.importProgress {
                HStack(spacing: 8) {
                    ProgressView(value: p.total > 0 ? Double(p.done) : nil, total: Double(max(p.total, 1)))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(p.total > 0 ? "Importing \(p.done + 1) of \(p.total)" : "Looking for audio…")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(p.current).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            } else if library.isGeneratingDemo {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing demo collection…").font(.system(size: 11.5, weight: .semibold))
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 12) {
                CollectionSearchField(text: $state.searchText, focusRequest: state.searchFocusRequest)
                    .frame(width: 210, height: 28)

                Button { AppEnvironment.shared.visualizer.show() } label: {
                    Image(systemName: "waveform.path")
                }
                .accessibilityLabel("MilkDrop Visualizer").help("Open MilkDrop Visualizer (⌘3)")

                Button { state.showQueue.toggle() } label: { Image(systemName: "sidebar.right") }
                    .accessibilityLabel("Queue").help("Show or hide the queue (⌘U)")

                Menu {
                    Button("Import Music…") { library.presentImportPanel() }
                        .disabled(library.importProgress != nil)
                    Divider()
                    Picker("Sort By", selection: $state.sortOrder) {
                        ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Collection options").help("Import music and sort albums")
            }
        }
    }
}

struct StatusBanners: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 8) {
            if let report = library.lastReport {
                Banner(icon: report.added > 0 ? "checkmark.circle" : "info.circle",
                       tone: report.added > 0 ? .success : .warning,
                       onClose: { library.lastReport = nil }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.headline).font(.system(size: 12.5, weight: .semibold))
                        ForEach(report.details, id: \.self) { Text($0).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
                .task(id: report.id) {
                    try? await Task.sleep(for: .seconds(report.details.isEmpty ? 6 : 14))
                    if library.lastReport?.id == report.id { withAnimation { library.lastReport = nil } }
                }
            }
            if let error = player.errorMessage {
                Banner(icon: "exclamationmark.triangle", tone: .error, onClose: { player.errorMessage = nil }) {
                    Text(error).font(.system(size: 12.5, weight: .medium)).lineLimit(3)
                }
                .task(id: error) {
                    try? await Task.sleep(for: .seconds(9))
                    if player.errorMessage == error { withAnimation { player.errorMessage = nil } }
                }
            }
            if let notice = library.notice {
                Banner(icon: "info.circle", tone: .warning, onClose: { library.notice = nil }) {
                    Text(notice).font(.system(size: 12.5, weight: .medium)).lineLimit(4)
                }
            }
        }
        .frame(maxWidth: 560)
        .animation(.easeOut(duration: 0.2), value: player.errorMessage)
    }
}

struct Banner<Content: View>: View {
    enum Tone { case info, success, warning, error }
    let icon: String
    let tone: Tone
    var onClose: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme

    init(icon: String, tone: Tone, onClose: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon
        self.tone = tone
        self.onClose = onClose
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
            content()
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline(scheme)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .info: return Palette.accent(scheme)
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct EmptyCollectionView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Palette.raised(scheme))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.hairline(scheme)))
                        .frame(width: 130, height: 130)
                        .rotation3DEffect(.degrees(Double(i - 1) * 50), axis: (0, 1, 0), perspective: 0.5)
                        .offset(x: CGFloat(i - 1) * 96)
                        .zIndex(i == 1 ? 1 : 0)
                }
                Image(systemName: "music.note")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                    .zIndex(2)
            }
            .frame(height: 150)
            .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Your record collection is empty")
                    .font(Typography.albumTitle(26))
                Text("Import audio files or whole folders. Cover Flow reads tags and embedded artwork, groups tracks into albums, and leaves your files where they are.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            HStack(spacing: 12) {
                Button { library.presentImportPanel() } label: { Label("Import Music…", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle(prominent: true))
                Button { library.addDemoCollection() } label: { Label("Add Demo Collection", systemImage: "sparkles") }
                    .buttonStyle(PillButtonStyle())
                    .disabled(library.isGeneratingDemo)
            }
            Text("You can also drop files or folders anywhere in this window.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }
}

struct NoResultsView: View {
    let query: String
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("No albums match “\(query)”")
                .font(Typography.albumTitle(20))
            Text("Search looks at album titles, artists and track names.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Clear Search") { state.searchText = "" }
                .buttonStyle(PillButtonStyle())
        }
    }
}

/// Asks before removing an album. Attached both to the main window and to the album sheet,
/// since a dialog can only be presented from the frontmost one.
struct RemoveAlbumConfirmation: ViewModifier {
    let active: Bool
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var state: AppState

    func body(content: Content) -> some View {
        content.confirmationDialog("Remove this album from your collection?",
                                   isPresented: Binding(get: { active && state.confirmRemoval != nil },
                                                        set: { if !$0 { state.confirmRemoval = nil } }),
                                   presenting: state.confirmRemoval) { ref in
            Button("Remove", role: .destructive) {
                if state.detailAlbum?.id == ref.id { state.detailAlbum = nil }
                library.removeAlbums([ref.id])
                state.confirmRemoval = nil
            }
            Button("Cancel", role: .cancel) { state.confirmRemoval = nil }
        } message: { ref in
            let isDemo = library.album(ref.id)?.isDemo ?? false
            Text(isDemo ? "The generated demo audio for this album will be deleted."
                        : "Your audio files stay where they are on disk; only Cover Flow’s entry is removed.")
        }
    }
}
