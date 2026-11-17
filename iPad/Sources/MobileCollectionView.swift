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
  /// Albums open in the side panel beside the browser instead of a sheet.
  var inlineAlbums = false
  @EnvironmentObject private var library: LibraryStore
  @EnvironmentObject private var player: PlayerEngine
  @EnvironmentObject private var app: MobileEnvironment
  @Environment(\.foldGeometry) private var fold
  @State private var search = ""
  @AppStorage("mobile.browse") private var browse = "coverFlow"
  @AppStorage("mobile.sort") private var sortValue = "artist"
  @AppStorage("mobile.focusedAlbum") private var focusedAlbum = ""
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
          MobileCoverFlow(albums: albums, selected: inlineAlbums ? app.albumPanel : nil, onOpen: open) {
            album in albumMenu(album)
          }
        } else {
          ScrollView {
            LazyVGrid(
              columns: fold.posture == .book && !inlineAlbums
                ? Array(
                  repeating: GridItem(.flexible(minimum: 120, maximum: 260), spacing: 22),
                  count: fold.gridColumns(minimumWidth: 172))
                : [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 22)], spacing: 24
            ) {
              ForEach(albums) { album in
                Button {
                  open(album)
                } label: {
                  VStack(alignment: .leading, spacing: 8) {
                    MobileArtwork(album: album).overlay {
                      if inlineAlbums && app.albumPanel == album.id && !selecting {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(MobilePalette.brass, lineWidth: 3)
                      }
                    }.overlay(alignment: .topTrailing) {
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
    .searchable(
      text: $search, isPresented: $app.searchPresented, prompt: "Albums, artists, and tracks")
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
    .sheet(
      item: Binding(
        get: { inlineAlbums ? nil : app.albumSheet.map { IDRef(id: $0) } },
        set: { app.albumSheet = $0?.id })
    ) { id in
      if let album = library.album(id.id) { MobileAlbumView(albumID: album.id) }
    }
    .onChange(of: app.revealPlaying) { _, _ in
      guard let id = player.currentAlbumID, library.album(id) != nil else { return }
      search = ""
      if browse != "coverFlow" { browse = "coverFlow" }
      focusedAlbum = id.uuidString
      if inlineAlbums { app.albumPanel = id } else { app.albumSheet = id }
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
      app.open(album: album.id, expanded: inlineAlbums)
    }
  }
  @ViewBuilder private func albumMenu(_ album: Album) -> some View {
    Button("Play", systemImage: "play.fill") { player.play(albumID: album.id) }
    Button("Shuffle", systemImage: "shuffle") { player.play(albumID: album.id, shuffled: true) }
    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
      player.playNext(album.trackIDs)
    }
    Button("Add to Queue", systemImage: "text.append") { player.addToQueue(album.trackIDs) }
    Button("Album Details", systemImage: "info.circle") {
      app.open(album: album.id, expanded: inlineAlbums)
    }
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
  /// The album shown in the side panel, outlined so the panel's subject is clear.
  var selected: UUID? = nil
  let onOpen: (Album) -> Void
  @ViewBuilder var menuContent: (Album) -> MenuContent
  @State private var focused: UUID?
  /// The centred album turned over to show its back, discs or open jewel case.
  @State private var flipped: UUID?
  @AppStorage(CoverTurnStyle.defaultsKey) private var turnStyle: CoverTurnStyle = .flipWithDiscs
  @AppStorage("mobile.focusedAlbum") private var savedFocused = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.hingeDegrees) private var hinge
  @FocusState private var keyboardFocus: Bool
  /// Partially opened like a laptop, covers lean back a little with the hinge,
  /// like records standing on a shelf. An effect only; layout never depends on it.
  private var hingeTilt: Double {
    guard let hinge, !reduceMotion else { return 0 }
    return max(0, min(14, (180 - hinge) / 6))
  }
  private func step(_ delta: Int) {
    guard !albums.isEmpty else { return }
    let index = focused.flatMap { id in albums.firstIndex { $0.id == id } } ?? 0
    let target = min(albums.count - 1, max(0, index + delta))
    withAnimation(reduceMotion ? nil : .spring(duration: 0.35)) { focused = albums[target].id }
  }
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
                let isFlipped = flipped == album.id
                VStack(spacing: 14) {
                  Button {
                    onOpen(album)
                  } label: {
                    ZStack {
                      if turnStyle == .flipWithDiscs && !album.discImages.isEmpty {
                        DiscStack(album: album, size: size, out: isFlipped, reduceMotion: reduceMotion)
                      } else if turnStyle == .flipWithSpinningDisc {
                        DiscStack(album: album, size: size, out: isFlipped, reduceMotion: reduceMotion, spin: true)
                      }
                      sleeve(album, size: size, flipped: isFlipped)
                        .overlay {
                          if selected == album.id {
                            RoundedRectangle(cornerRadius: 12).strokeBorder(
                              MobilePalette.brass, lineWidth: 3)
                          }
                        }
                        .shadow(color: .black.opacity(0.3), radius: 16, y: 12)
                    }
                    .frame(width: size, height: size)
                    .overlay(alignment: .bottom) {
                      Group {
                        if isFlipped { sleeve(album, size: size, flipped: true) } else { MobileCoverArt(album: album, size: size) }
                      }
                        .scaleEffect(x: 1, y: -1)
                        .frame(width: size, height: 60, alignment: .top).clipped()
                        .mask(
                          LinearGradient(
                            colors: [.white.opacity(0.18), .clear], startPoint: .top,
                            endPoint: .bottom)
                        )
                        .offset(y: 68).accessibilityHidden(true).allowsHitTesting(false)
                    }
                  }.buttonStyle(.plain)
                  VStack(spacing: 4) {
                    Text(album.title).font(.system(.title3, design: .serif).weight(.semibold))
                      .lineLimit(2)
                    HStack(spacing: 8) {
                      Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                      if focused == album.id {
                        Button {
                          toggleFlip(album)
                        } label: {
                          Image(systemName: turnStyle == .jewelCase ? "opticaldisc" : "rectangle.2.swap")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 34, height: 30)
                            .background(.thinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(flipLabel(isFlipped))
                        .contextMenu { turnStylePicker }
                      }
                    }
                  }.multilineTextAlignment(.center).padding(.top, 45)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(album) }
                }.foregroundStyle(.primary)
                  .accessibilityElement(children: .contain)
                  .accessibilityAction(named: flipLabel(isFlipped)) { toggleFlip(album) }
                  .rotation3DEffect(
                    .degrees(reduceMotion ? 0 : -max(-1, min(1, offset)) * 40),
                    axis: (x: 0, y: 1, z: 0), perspective: 0.5
                  )
                  .scaleEffect(reduceMotion ? 1 : 1 - min(0.14, abs(offset) * 0.1))
                  .contextMenu {
                    Button(flipLabel(isFlipped), systemImage: turnStyle == .jewelCase ? "opticaldisc" : "rectangle.2.swap") {
                      if focused != album.id {
                        withAnimation(reduceMotion ? nil : .spring(duration: 0.35)) { focused = album.id }
                      }
                      toggleFlip(album)
                    }
                    Menu("Turning Covers Over", systemImage: "rectangle.2.swap") { turnStylePicker }
                    Divider()
                    menuContent(album)
                  }
              }.frame(width: size, height: size + 130).id(album.id)
                .zIndex(flipped == album.id ? 1 : 0)
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
        .onChange(of: focused) { _, id in
          if let id { savedFocused = id.uuidString }
          if flipped != nil && flipped != id { setFlipped(nil) }
        }
        .onChange(of: savedFocused) { _, value in
          // Another view asked to reveal an album (⌘L, Show Playing Album).
          if let id = UUID(uuidString: value), id != focused, albums.contains(where: { $0.id == id }) {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.45)) { focused = id }
          }
        }
        .frame(width: container.size.width, height: layout.stageHeight)
        .rotation3DEffect(.degrees(hingeTilt), axis: (x: 1, y: 0, z: 0), perspective: 0.35)
      }.scrollBounceBehavior(.basedOnSize)
      // Hardware keyboards: arrows browse, Home/End jump, Return opens, as on the Mac.
      .focusable()
      .focused($keyboardFocus)
      .focusEffectDisabled()
      .onKeyPress(.leftArrow) {
        step(-1)
        return .handled
      }
      .onKeyPress(.rightArrow) {
        step(1)
        return .handled
      }
      .onKeyPress(.home) {
        step(-albums.count)
        return .handled
      }
      .onKeyPress(.end) {
        step(albums.count)
        return .handled
      }
      .onKeyPress(.pageUp) {
        step(-5)
        return .handled
      }
      .onKeyPress(.pageDown) {
        step(5)
        return .handled
      }
      .onKeyPress(.return) {
        guard let id = focused, let album = albums.first(where: { $0.id == id }) else {
          return .ignored
        }
        onOpen(album)
        return .handled
      }
      // F turns the centred cover over, as on the Mac.
      .onKeyPress(characters: CharacterSet(charactersIn: "fF"), phases: .down) { press in
        guard press.modifiers.intersection([.command, .control, .option]).isEmpty,
          let id = focused, let album = albums.first(where: { $0.id == id })
        else { return .ignored }
        toggleFlip(album)
        return .handled
      }
    }
  }

  @ViewBuilder private func sleeve(_ album: Album, size: CGFloat, flipped: Bool) -> some View {
    if turnStyle == .jewelCase {
      JewelCaseView(openness: flipped ? 1 : 0, album: album, size: size, reduceMotion: reduceMotion)
    } else {
      FlippableCover(angle: flipped ? 180 : 0, reduceMotion: reduceMotion) {
        MobileCoverArt(album: album, size: size)
      } back: {
        BackCoverView(album: album, size: size)
      }
      .frame(width: size, height: size)
    }
  }

  private var turnStylePicker: some View {
    Picker("Turning Covers Over", selection: $turnStyle) {
      ForEach(CoverTurnStyle.allCases) { Text($0.label).tag($0) }
    }
  }

  private func flipLabel(_ isFlipped: Bool) -> String {
    turnStyle == .jewelCase ? (isFlipped ? "Close Case" : "Open Case") : (isFlipped ? "Show Front" : "Flip Cover")
  }

  private func toggleFlip(_ album: Album) {
    setFlipped(flipped == album.id ? nil : album.id)
  }

  private func setFlipped(_ id: UUID?) {
    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.86)) {
      flipped = id
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
