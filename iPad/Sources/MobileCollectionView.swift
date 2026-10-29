import PhotosUI
import SwiftUI

struct MobileArtwork: View {
  let album: Album
  var pixels = 600
  @EnvironmentObject private var library: LibraryStore
  @State private var image: UIImage?
  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(hex: album.tintHex, fallback: MobilePalette.navy), MobilePalette.navy],
        startPoint: .topLeading, endPoint: .bottomTrailing)
      if let image {
        Image(uiImage: image).resizable().scaledToFit()
      } else {
        VStack(spacing: 12) {
          Image(systemName: "opticaldisc.fill").font(.system(size: 64, weight: .ultraLight))
          Text(album.title).font(.system(.title3, design: .serif)).multilineTextAlignment(.center)
            .lineLimit(3).padding(.horizontal)
        }.foregroundStyle(MobilePalette.cream)
      }
    }
    .aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
    .task(id: "\(album.artworkKey)-\(pixels)") {
      let result = await library.artwork.thumbnail(album, pixels: pixels)
      if !Task.isCancelled { image = result }
    }
    .accessibilityLabel("\(album.title) cover")
  }
}
struct MobileCollectionView: View {
  let importFiles: (Bool) -> Void
  @EnvironmentObject private var library: LibraryStore
  @EnvironmentObject private var player: PlayerEngine
  @State private var search = ""
  @AppStorage("mobile.browse") private var browse = "coverFlow"
  @AppStorage("mobile.sort") private var sortValue = "artist"
  @State private var detail: IDRef?
  @State private var selecting = false
  @State private var selection = Set<UUID>()
  @State private var removeSelected = false
  private var albums: [Album] {
    library.visibleAlbums(sort: SortOrder(rawValue: sortValue) ?? .artist, search: search)
  }
  var body: some View {
    VStack(spacing: 0) {
      if albums.isEmpty {
        if library.albums.isEmpty {
          ContentUnavailableView {
            Label("Your music, by its covers", systemImage: "square.stack.3d.up.fill")
          } description: {
            Text(
              "Import audio files or a folder from Files, iCloud Drive, or an attached drive. Your music stays available on this device."
            )
          } actions: {
            Button("Import Music") { importFiles(false) }.buttonStyle(.borderedProminent)
            Button("Try the demo collection") { Task { await library.addDemoCollection() } }
              .disabled(library.importing)
          }
        } else {
          ContentUnavailableView.search(text: search)
        }
      } else {
        if selecting { selectionBar }
        if browse == "coverFlow" {
          MobileCoverFlow(albums: albums, onOpen: open) { album in albumMenu(album) }
        } else {
          ScrollView {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 22)], spacing: 24
            ) {
              ForEach(albums) { album in
                Button {
                  open(album)
                } label: {
                  VStack(alignment: .leading, spacing: 8) {
                    MobileArtwork(album: album).overlay(alignment: .topTrailing) {
                      if selecting {
                        Image(
                          systemName: selection.contains(album.id)
                            ? "checkmark.circle.fill" : "circle"
                        ).font(.title2).foregroundStyle(.white, MobilePalette.navy).padding(8)
                      }
                    }
                    Text(album.title).font(.system(.headline, design: .serif)).foregroundStyle(
                      .primary
                    ).lineLimit(2).multilineTextAlignment(.leading)
                    Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  }
                }.buttonStyle(.plain).contextMenu { albumMenu(album) }
              }
            }.padding(24)
          }
        }
        HStack {
          Text("\(albums.count) albums · \(library.tracks.count) tracks")
          Spacer()
          Text(formatLongDuration(library.tracks.values.reduce(0) { $0 + $1.duration }))
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 10)
      }
    }
    .searchable(text: $search, prompt: "Albums, artists, and tracks")
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Picker("Browse", selection: $browse) {
          Image(systemName: "rectangle.stack").tag("coverFlow")
          Image(systemName: "square.grid.2x2").tag("grid")
        }.pickerStyle(.segmented).frame(width: 105)
        Menu {
          Picker("Sort albums", selection: $sortValue) {
            ForEach(SortOrder.allCases) { Text($0.label).tag($0.rawValue) }
          }
          Button(selecting ? "Done Selecting" : "Select Albums") {
            selecting.toggle()
            if selecting { browse = "grid" } else { selection = [] }
          }
        } label: {
          Image(systemName: "line.3.horizontal.decrease")
        }.accessibilityLabel("Sort and select albums")
      }
    }
    .sheet(item: $detail) { id in
      if let album = library.album(id.id) { MobileAlbumView(albumID: album.id) }
    }
    .confirmationDialog(
      "Remove these albums and their imported copies from this device?",
      isPresented: $removeSelected,
      titleVisibility: .visible
    ) {
      Button("Remove Albums", role: .destructive) {
        library.removeAlbums(selection)
        selection = []
        selecting = false
      }
    }
  }
  private func open(_ album: Album) {
    if selecting {
      if selection.contains(album.id) {
        selection.remove(album.id)
      } else {
        selection.insert(album.id)
      }
    } else {
      detail = IDRef(id: album.id)
    }
  }
  @ViewBuilder private func albumMenu(_ album: Album) -> some View {
    Button("Play", systemImage: "play.fill") { player.play(albumID: album.id) }
    Button("Shuffle", systemImage: "shuffle") { player.play(albumID: album.id, shuffled: true) }
    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
      player.playNext(album.trackIDs)
    }
    Button("Add to Queue", systemImage: "text.append") { player.addToQueue(album.trackIDs) }
    Button("Album Details", systemImage: "info.circle") { detail = IDRef(id: album.id) }
  }
  private var selectionBar: some View {
    HStack {
      Text("\(selection.count) selected")
      Spacer()
      Menu("Play & Queue") {
        let ids = albums.filter { selection.contains($0.id) }.flatMap(\.trackIDs)
        Button("Play") { player.setQueue(ids, startIndex: 0, autoplay: true, shuffled: false) }
        Button("Shuffle") { player.setQueue(ids, startIndex: 0, autoplay: true, shuffled: true) }
        Button("Play Next") { player.playNext(ids) }
        Button("Add to Queue") { player.addToQueue(ids) }
      }.disabled(selection.isEmpty)
      Button(role: .destructive) {
        removeSelected = true
      } label: {
        Image(systemName: "trash")
      }.disabled(selection.isEmpty)
    }.padding().background(.thinMaterial)
  }
}
struct MobileCoverFlow<MenuContent: View>: View {
  let albums: [Album]
  let onOpen: (Album) -> Void
  @ViewBuilder var menuContent: (Album) -> MenuContent
  @State private var focused: UUID?
  @AppStorage("mobile.focusedAlbum") private var savedFocused = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    GeometryReader { container in
      let layout = MobileCoverLayout(width: container.size.width, height: container.size.height)
      let size = CGFloat(layout.coverSide)
      ScrollView(.vertical) {
        ScrollView(.horizontal) {
          LazyHStack(spacing: 24) {
            ForEach(albums) { album in
              GeometryReader { card in
                let center = card.frame(in: .named("covers")).midX
                let offset = (center - container.size.width / 2) / max(size, 1)
                Button {
                  onOpen(album)
                } label: {
                  VStack(spacing: 14) {
                    MobileArtwork(album: album, pixels: 900)
                      .shadow(color: .black.opacity(0.3), radius: 16, y: 12)
                      .overlay(alignment: .bottom) {
                        MobileArtwork(album: album, pixels: 600)
                          .frame(width: size, height: size).scaleEffect(x: 1, y: -1)
                          .frame(width: size, height: 60, alignment: .top).clipped()
                          .mask(
                            LinearGradient(
                              colors: [.white.opacity(0.18), .clear], startPoint: .top,
                              endPoint: .bottom)
                          )
                          .offset(y: 68).accessibilityHidden(true)
                      }
                    VStack(spacing: 4) {
                      Text(album.title).font(.system(.title3, design: .serif).weight(.semibold))
                        .lineLimit(2)
                      Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }.multilineTextAlignment(.center).padding(.top, 45)
                  }.foregroundStyle(.primary)
                }.buttonStyle(.plain)
                  .rotation3DEffect(
                    .degrees(reduceMotion ? 0 : -max(-1, min(1, offset)) * 40),
                    axis: (x: 0, y: 1, z: 0), perspective: 0.5
                  )
                  .scaleEffect(reduceMotion ? 1 : 1 - min(0.14, abs(offset) * 0.1))
                  .contextMenu { menuContent(album) }
              }.frame(width: size, height: size + 130).id(album.id)
            }
          }.scrollTargetLayout()
            .padding(.horizontal, max(0, (container.size.width - size) / 2))
            .padding(.vertical, 6).frame(minHeight: layout.stageHeight)
        }
        .scrollTargetBehavior(MobileCoverSnapping(step: size + 24, count: albums.count))
        .scrollPosition(id: $focused, anchor: .center).coordinateSpace(name: "covers")
        .defaultScrollAnchor(.center)
        .onChange(of: albums.map(\.id), initial: true) { _, ids in
          if focused == nil || !ids.contains(focused!) {
            focused =
              UUID(uuidString: savedFocused).flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
          }
        }
        .onChange(of: focused) { _, id in if let id { savedFocused = id.uuidString } }
        .frame(width: container.size.width, height: layout.stageHeight)
      }.scrollBounceBehavior(.basedOnSize)
    }
  }
}

private struct MobileCoverSnapping: ScrollTargetBehavior {
  let step: CGFloat
  let count: Int
  func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
    target.rect.origin.x = MobileCoverLayout.snapOffset(
      predicted: target.rect.minX, step: step, count: count)
  }
}
