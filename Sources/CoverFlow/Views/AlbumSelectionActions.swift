import SwiftUI

struct AlbumSelectionBar: View {
    let albums: [Album]
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: PlayerEngine

    private var selected: [Album] { albums.filter { state.selection.ids.contains($0.id) } }
    private var tracks: [UUID] { selected.flatMap(\.trackIDs) }

    var body: some View {
        HStack(spacing: 14) {
            Text("\(selected.count) selected").font(.system(size: 12, weight: .semibold))
            Button("Play") { player.setQueue(tracks, startIndex: 0, autoplay: true) }
            Button("Play Next") { player.playNext(tracks) }
            Button("Add to Queue") { player.addToQueue(tracks) }
            Spacer()
            Button("Remove…", role: .destructive) { state.selectedAlbumRemoval = selected.map(\.id) }
            Button("Clear Selection") { state.selection.clear() }
        }
        .controlSize(.small)
        .padding(.horizontal, 20).padding(.vertical, 9)
        .background(.thinMaterial)
    }
}

struct SelectedAlbumBadge: View {
    let selected: Bool
    var body: some View {
        if selected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.white, Color.accentColor)
                .shadow(color: .black.opacity(0.4), radius: 3)
                .padding(10)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
