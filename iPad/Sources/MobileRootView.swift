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
  private var usesTabs: Bool {
    UIDevice.current.userInterfaceIdiom == .phone || widthClass == .compact
  }

  var body: some View {
    Group {
      if usesTabs { phoneNavigation } else { tabletNavigation }
    }
    .onChange(of: usesTabs) { _, compact in
      if !compact, app.tab == .more { app.tab = .settings }
    }
    .sheet(isPresented: $app.nowPlaying) { MobileNowPlayingView() }
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
    .background {
      Button("Play or pause") { player.togglePlayPause() }.keyboardShortcut(
        "p", modifiers: .command
      ).hidden()
    }
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
        .toolbar { importToolbar }
        .navigationDestination(for: MobileTab.self) { route in
          destination(route).navigationTitle(route.title).toolbar { importToolbar }
        }
      }
    } else {
      NavigationStack {
        destination(tab).navigationTitle(tab.title).toolbar { importToolbar }
      }
    }
  }

  private var tabletNavigation: some View {
    NavigationSplitView {
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
          Button("Audio files", systemImage: "music.note") { importingFiles = true }
          Button("A folder", systemImage: "folder") { importingFolder = true }
        } label: {
          Label("Import Music", systemImage: "plus.circle.fill")
            .frame(maxWidth: .infinity).padding(.vertical, 10)
        }.buttonStyle(.borderedProminent).padding()
      }
    } detail: {
      NavigationStack {
        destination(app.tab).navigationTitle(app.tab.title).toolbar { importToolbar }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) { MobilePlaybackBar() }
  }

  @ViewBuilder private func destination(_ tab: MobileTab) -> some View {
    switch tab {
    case .library:
      MobileCollectionView(importFiles: { $0 ? (importingFolder = true) : (importingFiles = true) })
    case .queue: MobileQueueView()
    case .lyrics: MobileLyricsView()
    case .karaoke: MobileKaraokeView()
    case .visualizer: MobileVisualizerView()
    case .settings: MobileSettingsView()
    case .more: EmptyView()
    }
  }

  @ToolbarContentBuilder private var importToolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      Menu {
        Button("Import audio files", systemImage: "music.note") { importingFiles = true }
        Button("Import folder", systemImage: "folder") { importingFolder = true }
        Button("Now Playing", systemImage: "play.circle") { app.nowPlaying = true }
      } label: {
        Image(systemName: "plus").frame(width: 32, height: 32)
      }.accessibilityLabel("Import music and player actions")
    }
  }

}
