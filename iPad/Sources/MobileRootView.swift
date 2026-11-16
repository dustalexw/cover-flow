import SwiftUI
import UniformTypeIdentifiers

struct MobileRootView: View {
  @EnvironmentObject private var app: MobileEnvironment
  @EnvironmentObject private var library: LibraryStore
  @EnvironmentObject private var player: PlayerEngine
  @EnvironmentObject private var karaoke: MobileKaraokeStore
  @State private var importingFiles = false
  @State private var importingFolder = false
  @Environment(\.horizontalSizeClass) private var widthClass
  @Environment(\.verticalSizeClass) private var heightClass
  /// iPhone Duo's outer display (and every other iPhone) is compact; its inner display
  /// and iPad are regular in both dimensions. Landscape Plus/Max phones report regular
  /// width with compact height and keep the phone layout.
  private var layout: MobileLayoutClass {
    MobileLayoutClass(regularWidth: widthClass == .regular, regularHeight: heightClass == .regular)
  }

  var body: some View {
    Group {
      switch layout {
      case .compact: phoneNavigation
      case .expanded:
        MobileExpandedShell(
          importFiles: { $0 ? (importingFolder = true) : (importingFiles = true) })
      }
    }
    .onChange(of: layout, initial: true) { _, value in app.layoutChanged(to: value) }
    .observesHinge()
    .sheet(isPresented: $app.nowPlaying) { MobileNowPlayingView() }
    .fullScreenCover(isPresented: $app.immersive) { MobileImmersiveAlbumView() }
    .fileImporter(
      isPresented: $importingFiles, allowedContentTypes: [.audio, .movie, .data],
      allowsMultipleSelection: true
    ) { result in
      if case .success(let urls) = result {
        Task { await library.importURLs(urls) }
      } else if case .failure(let error) = result {
        library.notice = error.localizedDescription
      }
    }
    .fileImporter(isPresented: $importingFolder, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result {
        Task { await library.importURLs([url]) }
      } else if case .failure(let error) = result {
        library.notice = error.localizedDescription
      }
    }
    .alert(
      "Import complete",
      isPresented: Binding(
        get: { library.lastReport != nil }, set: { if !$0 { library.lastReport = nil } })
    ) {
      Button("OK") { library.lastReport = nil }
    } message: {
      Text(
        (library.lastReport?.summary ?? "")
          + (library.lastReport?.failures.isEmpty == false
            ? "\n\n" + (library.lastReport?.failures.prefix(12).joined(separator: "\n") ?? "") : "")
      )
    }
    .alert(
      "Cover Flow",
      isPresented: Binding(
        get: { library.notice != nil || player.errorMessage != nil },
        set: {
          if !$0 {
            library.notice = nil
            player.errorMessage = nil
          }
        })
    ) {
      Button("OK") {
        library.notice = nil
        player.errorMessage = nil
      }
    } message: {
      Text(library.notice ?? player.errorMessage ?? "")
    }
    .onChange(of: player.currentTrackID, initial: true) { _, _ in
      karaoke.refresh(player.currentTrack)
    }
    .overlay(alignment: .top) {
      if library.importing {
        HStack {
          VStack(alignment: .leading) {
            Text("Importing \(library.importLabel)").font(.caption).lineLimit(1)
            ProgressView(value: library.importFraction)
          }
          Button("Cancel") { library.cancel() }
        }
        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding()
        .frame(maxWidth: 600)
      }
    }
    .background { MobileKeyCommands(layout: layout) }
  }
  private var phoneNavigation: some View {
    TabView(selection: Binding(get: { app.tab.compactSelection }, set: { app.tab = $0 })) {
      ForEach(MobileTab.compactTabs) { tab in
        phoneStack(tab)
          .safeAreaInset(edge: .bottom, spacing: 0) { MobilePlaybackBar() }
          .tabItem { Label(tab.title, systemImage: tab.icon) }
          .tag(tab)
      }
    }
  }

  @ViewBuilder private func phoneStack(_ tab: MobileTab) -> some View {
    if tab == .more {
      NavigationStack(
        path: Binding<[MobileTab]>(
          get: { app.tab.isSecondaryDestination ? [app.tab] : [] },
          set: { app.tab = $0.last ?? .more })
      ) {
        List {
          ForEach([MobileTab.visualizer, .settings]) { route in
            NavigationLink(value: route) { Label(route.title, systemImage: route.icon) }
          }
        }
        .navigationTitle("More")
        .toolbar { MobileImportToolbar(importFiles: importFiles, app: app) }
        .navigationDestination(for: MobileTab.self) { route in
          MobileDestination(tab: route, inlineAlbums: false, importFiles: importFiles)
            .navigationTitle(route.title).toolbar { MobileImportToolbar(importFiles: importFiles, app: app) }
        }
      }
    } else {
      NavigationStack {
        MobileDestination(tab: tab, inlineAlbums: false, importFiles: importFiles)
          .navigationTitle(tab.title).toolbar { MobileImportToolbar(importFiles: importFiles, app: app) }
      }
    }
  }
  private func importFiles(_ folder: Bool) {
    if folder { importingFolder = true } else { importingFiles = true }
  }
}

/// The destination for a tab, shared by the phone tabs and the expanded sidebar.
struct MobileDestination: View {
  let tab: MobileTab
  let inlineAlbums: Bool
  let importFiles: (Bool) -> Void
  var body: some View {
    switch tab {
    case .library:
      MobileCollectionView(importFiles: importFiles, inlineAlbums: inlineAlbums)
    case .queue: MobileQueueView()
    case .lyrics: MobileLyricsView()
    case .karaoke: MobileKaraokeView()
    case .visualizer: MobileVisualizerView()
    case .settings: MobileSettingsView()
    case .more: EmptyView()
    }
  }
}

struct MobileImportToolbar: ToolbarContent {
  let importFiles: (Bool) -> Void
  let app: MobileEnvironment
  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      Menu {
        Button("Import audio files", systemImage: "music.note") { importFiles(false) }
        Button("Import folder", systemImage: "folder") { importFiles(true) }
        Divider()
        Button("Album View", systemImage: "play.rectangle") { app.nowPlaying = true }
        Button("Immersive Album View", systemImage: "arrow.up.left.and.arrow.down.right") {
          app.immersive = true
        }
        Button("Show Playing Album", systemImage: "scope") {
          app.tab = .library
          app.revealPlaying += 1
        }
      } label: {
        Image(systemName: "plus").frame(width: 32, height: 32)
      }.accessibilityLabel("Import music and player actions")
    }
  }
}

/// The inner-display shell for iPhone Duo (and iPad): a sidebar, the browser with the
/// album track panel beside it, and a full-width player bar. In book posture the
/// browser and album panel become the two pages either side of the fold; in tabletop
/// posture Album View stands up with artwork above the fold and controls below.
struct MobileExpandedShell: View {
  let importFiles: (Bool) -> Void
  @EnvironmentObject private var app: MobileEnvironment
  /// The sidebar starts tucked away so Cover Flow fills the display; the sidebar
  /// button brings it back.
  @State private var columns: NavigationSplitViewVisibility = .detailOnly
  /// Set when the person leaves the tabletop player to browse; cleared when the pose changes.
  @State private var tabletopBrowsing = false
  var body: some View {
    FoldReader { fold in
      Group {
        if fold.posture == .tabletop && !tabletopBrowsing {
          MobileTabletopPlayer(fold: fold) { tabletopBrowsing = true }
        } else {
          split(fold)
        }
      }
      .environment(\.foldGeometry, fold)
      .onChange(of: fold.posture) { old, posture in
        if posture != old { tabletopBrowsing = false }
      }
    }
  }
  private func split(_ fold: FoldGeometry) -> some View {
    NavigationSplitView(columnVisibility: $columns) {
      List(
        MobileTab.sidebarTabs,
        selection: Binding<MobileTab?>(
          get: { app.tab }, set: { if let value = $0 { app.tab = value } })
      ) { tab in
        Label(tab.title, systemImage: tab.icon).tag(tab).padding(.vertical, 4)
      }
      .navigationTitle("Cover Flow")
      .safeAreaInset(edge: .bottom) {
        Menu {
          Button("Audio files", systemImage: "music.note") { importFiles(false) }
          Button("A folder", systemImage: "folder") { importFiles(true) }
        } label: {
          Label("Import Music", systemImage: "plus.circle.fill")
            .frame(maxWidth: .infinity).padding(.vertical, 10)
        }.buttonStyle(.borderedProminent).padding()
      }
    } detail: {
      NavigationStack {
        detail
          .navigationTitle(app.tab.title).toolbar { MobileImportToolbar(importFiles: importFiles, app: app) }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) { MobilePlaybackBar(fold: fold) }
  }
  @ViewBuilder private var detail: some View {
    // Cover Flow takes the whole display; albums open over it.
    MobileDestination(tab: app.tab, inlineAlbums: false, importFiles: importFiles)
  }
}
