import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Queue")
                    .font(Typography.albumTitle(18))
                Spacer()
                if !player.upNext.isEmpty {
                    Button("Clear Up Next") { player.clearUpNext() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            List {
                Section("Now Playing") {
                    if let track = player.currentTrack, let i = player.currentIndex {
                        QueueRow(track: track, album: library.album(library.albumID(forTrack: track.id)), isCurrent: true) {
                            player.togglePlayPause()
                        } onRemove: {
                            player.removeFromQueue(absoluteIndex: i)
                        }
                    } else {
                        Text("Nothing playing").foregroundStyle(.secondary)
                    }
                }
                Section {
                    if player.upNext.isEmpty {
                        Text("Nothing up next. Use Play Next or Add to Queue on any album or track.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(player.upNext) { entry in
                            if let track = library.track(entry.trackID) {
                                QueueRow(track: track, album: library.album(library.albumID(forTrack: track.id)), isCurrent: false) {
                                    player.jump(toAbsolute: entry.id)
                                } onRemove: {
                                    player.removeFromQueue(absoluteIndex: entry.id)
                                } onMove: { move in
                                    player.move(absoluteIndex: entry.id, move)
                                }
                            }
                        }
                        .onMove { player.moveUpNext(from: $0, to: $1) }
                        .onDelete { offsets in
                            let base = (player.currentIndex ?? -1) + 1
                            for o in offsets.sorted(by: >) { player.removeFromQueue(absoluteIndex: base + o) }
                        }
                    }
                } header: {
                    Text("Up Next" + (player.upNext.isEmpty ? "" : " · \(player.upNext.count)"))
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Text("Drag to reorder, or right-click a track to move it. The queue and position are saved.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(12)
        }
        .background(Palette.base(scheme).opacity(0.6))
    }
}

struct QueueRow: View {
    let track: Track
    let album: Album?
    let isCurrent: Bool
    let onActivate: () -> Void
    let onRemove: () -> Void
    var onMove: ((PlayerEngine.QueueMove) -> Void)? = nil
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onActivate) {
                ArtworkView(album: album, pointSize: 36, cornerRadius: 2)
                    .frame(width: 36, height: 36)
                    .overlay {
                        if isCurrent {
                            Color.black.opacity(0.45)
                            NowPlayingBars(playing: player.isPlaying, color: .white, height: 10)
                        } else if hover {
                            Color.black.opacity(0.45)
                            Image(systemName: "play.fill").font(.system(size: 12)).foregroundStyle(.white)
                        }
                    }
            }
            .buttonStyle(.borderless)
            .help(isCurrent ? "Play or pause" : "Play now")
            .accessibilityLabel(isCurrent ? "Play or pause" : "Play \(track.title) now")
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Palette.accent(scheme) : Color.primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hover {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Palette.raisedHover(scheme)))
                        .contentShape(Circle())
                }
                    .buttonStyle(.borderless)
                    .help("Remove from queue")
                    .accessibilityLabel("Remove \(track.title) from queue")
            } else {
                Text(formatTime(track.duration))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .onHover { hover = $0 }
        .contextMenu {
            Button(isCurrent ? "Play/Pause" : "Play Now", action: onActivate)
            if let onMove {
                Button("Move to Top") { onMove(.top) }
                Button("Move Up") { onMove(.up) }
                Button("Move Down") { onMove(.down) }
            }
            Divider()
            Button("Remove from Queue", action: onRemove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: isCurrent ? "Play or pause" : "Play now", onActivate)
        .accessibilityAction(named: "Remove from queue", onRemove)
    }
}
