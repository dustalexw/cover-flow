import SwiftUI
import AppKit

/// Presentation state shared by the main window, menus and Album View.
@MainActor
final class AppState: ObservableObject {
    @Published var browseMode: BrowseMode {
        didSet { UserDefaults.standard.set(browseMode.rawValue, forKey: "browseMode") }
    }
    @Published var sortOrder: SortOrder {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "sortOrder") }
    }
    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme"); AppEnvironment.shared.albumView.applyTheme() }
    }
    @Published var searchText = ""
    @Published var searchFocusRequest = 0
    /// The album being browsed. Independent from what is playing.
    @Published var browsedAlbumID: UUID? {
        didSet { UserDefaults.standard.set(browsedAlbumID?.uuidString, forKey: "browsedAlbum") }
    }
    @Published var selection = AlbumSelection()
    @Published var selectedAlbumRemoval: [UUID]?
    @Published var detailAlbum: IDRef?
    @Published var editAlbum: IDRef?
    @Published var showQueue: Bool {
        didSet { UserDefaults.standard.set(showQueue, forKey: "showQueue") }
    }
    @Published var confirmRemoval: IDRef?
    /// Bumped to ask the browser to scroll to an album (e.g. "Show playing album").
    @Published var revealRequest: RevealRequest?
    private var revealToken = 0

    init() {
        let d = UserDefaults.standard
        browseMode = BrowseMode(rawValue: d.string(forKey: "browseMode") ?? "") ?? .coverFlow
        sortOrder = SortOrder(rawValue: d.string(forKey: "sortOrder") ?? "") ?? .artist
        theme = AppTheme(rawValue: d.string(forKey: "theme") ?? "") ?? .dark
        browsedAlbumID = d.string(forKey: "browsedAlbum").flatMap(UUID.init(uuidString:))
        showQueue = d.bool(forKey: "showQueue")
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    func reveal(_ id: UUID?) {
        guard let id else { return }
        if !searchText.isEmpty { searchText = "" }
        revealToken += 1
        browsedAlbumID = id
        revealRequest = RevealRequest(id: id, token: revealToken)
    }
}

struct RevealRequest: Equatable {
    let id: UUID
    let token: Int
}

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let artwork: ArtworkStore
    let library: LibraryStore
    let player: PlayerEngine
    let lastfm: LastFmScrobbler
    let state: AppState
    let albumView: AlbumViewController
    lazy var visualizer = VisualizerController(player: player)

    private init() {
        artwork = ArtworkStore(directory: AppPaths.artwork)
        library = LibraryStore(artwork: artwork)
        lastfm = LastFmScrobbler()
        player = PlayerEngine(library: library, scrobbler: lastfm)
        state = AppState()
        albumView = AlbumViewController()
        library.load()
        player.restore()
        let d = UserDefaults.standard
        if !d.bool(forKey: "didSeedDemo") {
            d.set(true, forKey: "didSeedDemo")
            if library.albums.isEmpty { library.addDemoCollection() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (@MainActor () -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            if UserDefaults.standard.bool(forKey: "albumViewOpen") {
                AppEnvironment.shared.albumView.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            let env = AppEnvironment.shared
            env.player.saveNow()
            env.library.saveNow()
            env.albumView.persistOpenState()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            // Auxiliary windows can remain visible after the collection window closes.
            // Reopen the single SwiftUI scene rather than relying on AppKit's default.
            openMainWindow?()
            sender.activate(ignoringOtherApps: true)
        }
        return false
    }
}

private struct MainWindowReopenHandler: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let delegate: AppDelegate

    func body(content: Content) -> some View {
        content.onAppear {
            // Retain the scene action after its content disappears on window close.
            let action = openWindow
            delegate.openMainWindow = { action(id: "main") }
        }
    }
}

@main
struct CoverFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let env = AppEnvironment.shared

    var body: some Scene {
        Window("Cover Flow", id: "main") {
            RootView()
                .environmentObject(env.library)
                .environmentObject(env.player)
                .environmentObject(env.state)
                .environmentObject(env.albumView)
                .modifier(MainWindowReopenHandler(delegate: appDelegate))
        }
        .defaultSize(width: 1220, height: 820)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            AppCommands(player: env.player, state: env.state, library: env.library, albumView: env.albumView)
        }

        // A value-based group opens only on request and reuses the About window.
        WindowGroup("About Cover Flow", id: "about", for: String.self) { _ in
            AboutView().environmentObject(env.state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environmentObject(env.lastfm)
                .environmentObject(env.library)
                .environmentObject(env.player)
                .environmentObject(env.state)
                .environmentObject(env.albumView)
        }
    }
}

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var player: PlayerEngine
    @ObservedObject var state: AppState
    @ObservedObject var library: LibraryStore
    @ObservedObject var albumView: AlbumViewController

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Cover Flow…") { openWindow(id: "about", value: "about") }
        }

        CommandGroup(replacing: .newItem) {
            Button("Import Music…") { library.presentImportPanel() }
                .keyboardShortcut("o")
            Divider()
            Button(library.hasDemoContent ? "Rebuild Demo Collection" : "Add Demo Collection") { library.addDemoCollection() }
            if library.hasDemoContent {
                Button("Remove Demo Collection") { library.removeDemoCollection() }
            }
        }

        CommandGroup(before: .toolbar) {
            Button("Cover Flow") { state.browseMode = .coverFlow }
                .keyboardShortcut("1")
            Button("Grid") { state.browseMode = .grid }
                .keyboardShortcut("2")
            Button("MilkDrop Visualizer") { AppEnvironment.shared.visualizer.show() }
                .keyboardShortcut("3")
            Button("Search Music") { state.searchFocusRequest += 1 }
                .keyboardShortcut("f")
            Menu("Sort By") {
                ForEach(SortOrder.allCases) { order in
                    Button {
                        state.sortOrder = order
                    } label: {
                        if state.sortOrder == order { Label(order.label, systemImage: "checkmark") } else { Text(order.label) }
                    }
                }
            }
            Divider()
            Button(state.showQueue ? "Hide Queue" : "Show Queue") { state.showQueue.toggle() }
                .keyboardShortcut("u")
            Button("Show Playing Album") { state.reveal(player.currentAlbumID) }
                .keyboardShortcut("l")
                .disabled(!player.hasTrack)
            Divider()
            Button(albumView.isOpen ? "Close Album View" : "Open Album View") { albumView.toggle() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Menu("Album View Size") {
                Button("Compact") { albumView.apply(.compact) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Large") { albumView.apply(.large) }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Immersive") { albumView.apply(.immersive) }.keyboardShortcut("3", modifiers: [.command, .option])
            }
            Divider()
        }

        CommandMenu("Controls") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .keyboardShortcut("p")
                .disabled(!player.hasTrack)
            Button("Next Track") { player.next() }
                .keyboardShortcut(.rightArrow)
                .disabled(!player.hasTrack)
            Button("Previous Track") { player.previous() }
                .keyboardShortcut(.leftArrow)
                .disabled(!player.hasTrack)
            Divider()
            Button("Skip Forward 10 Seconds") { player.skip(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!player.hasTrack)
            Button("Skip Back 10 Seconds") { player.skip(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!player.hasTrack)
            Divider()
            Button("Increase Volume") { player.nudgeVolume(0.1) }
                .keyboardShortcut(.upArrow)
            Button("Decrease Volume") { player.nudgeVolume(-0.1) }
                .keyboardShortcut(.downArrow)
            Button(player.isMuted ? "Unmute" : "Mute") { player.toggleMute() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button(player.shuffle ? "Turn Shuffle Off" : "Turn Shuffle On") { player.toggleShuffle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button(player.repeatMode.next.label) { player.cycleRepeat() }
                .keyboardShortcut("r", modifiers: [.command, .control])
        }
    }
}
