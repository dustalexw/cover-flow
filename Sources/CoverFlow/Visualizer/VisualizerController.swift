import AppKit
import SwiftUI

struct MilkDropPreset: Identifiable, Equatable {
    let url: URL
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor
final class VisualizerController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isOpen = false
    @Published private(set) var presets: [MilkDropPreset] = []
    @Published private(set) var selected: MilkDropPreset?
    @Published var useMilkDrop = UserDefaults.standard.bool(forKey: "visualizer.useMilkDrop") {
        didSet { UserDefaults.standard.set(useMilkDrop, forKey: "visualizer.useMilkDrop"); error = nil; player.visualizerAudio.clear() }
    }
    @Published var style = VisualizerStyle(rawValue: UserDefaults.standard.integer(forKey: "visualizer.style")) ?? .pulse {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "visualizer.style") }
    }
    @Published var response: Double = UserDefaults.standard.object(forKey: "visualizer.response") as? Double ?? 1.25 {
        didSet { UserDefaults.standard.set(response, forKey: "visualizer.response") }
    }
    @Published var highQuality = UserDefaults.standard.object(forKey: "visualizer.highQuality") as? Bool ?? true {
        didSet { UserDefaults.standard.set(highQuality, forKey: "visualizer.highQuality") }
    }
    @Published var automatic = true
    @Published var error: String?
    private(set) var revision = 0
    let player: PlayerEngine
    private var window: NSWindow?
    private var keys: Any?
    private var lastChange = Date()

    init(player: PlayerEngine) {
        self.player = player
        super.init()
        reloadPresets()
        selected = presets.first
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Cover Flow Visualizer"
            w.minSize = NSSize(width: 720, height: 420)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.appearance = NSAppearance(named: .darkAqua)
            w.collectionBehavior = [.fullScreenPrimary]
            w.contentView = NSHostingView(rootView: VisualizerView(controller: self, player: player))
            w.center()
            w.setFrameAutosaveName("CoverFlow.Visualizer.Frame")
            window = w
        }
        isOpen = true
        error = nil
        lastChange = Date()
        player.visualizerAudio.setEnabled(true)
        window?.makeKeyAndOrderFront(nil)
        if keys == nil {
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, self.window?.attachedSheet == nil,
                      event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
                switch event.keyCode {
                case 49: if !event.isARepeat { self.player.togglePlayPause() }; return nil
                case 123: self.step(-1); return nil
                case 124: self.step(1); return nil
                case 53:
                    if self.window?.styleMask.contains(.fullScreen) == true { self.toggleFullScreen() }
                    else { self.window?.close() }
                    return nil
                default: return event
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        player.visualizerAudio.setEnabled(false)
        if let keys { NSEvent.removeMonitor(keys); self.keys = nil }
        window?.contentView = nil
        window = nil
    }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }
    func choose(_ preset: MilkDropPreset) {
        selected = preset
        revision += 1
        error = nil
        lastChange = Date()
    }
    func step(_ offset: Int) {
        if !useMilkDrop {
            let count = VisualizerStyle.allCases.count
            style = VisualizerStyle(rawValue: (style.rawValue + offset % count + count) % count) ?? .pulse
            lastChange = Date(); return
        }
        guard !presets.isEmpty else { return }
        let index = selected.flatMap { presets.firstIndex(of: $0) } ?? 0
        choose(presets[(index + offset % presets.count + presets.count) % presets.count])
    }
    func tick() {
        guard automatic, player.isPlaying, !player.isBuffering, Date().timeIntervalSince(lastChange) >= 25 else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if !useMilkDrop { step(1); return }
        let candidates = presets.filter { $0 != selected }
        if let next = candidates.randomElement() { choose(next) }
    }

    private var customDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoverFlow/Visualizer/Presets", isDirectory: true)
    }
    private func reloadPresets() {
        let bundled = Bundle.module.url(forResource: "Presets", withExtension: nil)
        presets = [bundled, customDirectory].compactMap { $0 }.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        }.filter { $0.pathExtension.lowercased() == "milk" }
            .map { MilkDropPreset(url: $0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func importPresets() {
        let panel = NSOpenPanel()
        panel.title = "Add MilkDrop Presets"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            do {
                try FileManager.default.createDirectory(at: self.customDirectory, withIntermediateDirectories: true)
                var added: URL?
                for url in panel.urls where url.pathExtension.lowercased() == "milk" {
                    // Keep existing presets when two imports have the same name.
                    var destination = self.customDirectory.appendingPathComponent(url.lastPathComponent)
                    var suffix = 2
                    while FileManager.default.fileExists(atPath: destination.path) {
                        destination = self.customDirectory.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) (\(suffix)).milk")
                        suffix += 1
                    }
                    try FileManager.default.copyItem(at: url, to: destination)
                    added = destination
                }
                self.reloadPresets()
                if let added, let preset = self.presets.first(where: { $0.url == added }) { self.choose(preset) }
                else { self.error = "Choose files ending in .milk to add MilkDrop presets." }
            } catch { self.error = "Couldn’t add presets: \(error.localizedDescription)" }
        }
    }
}

struct VisualizerView: View {
    @ObservedObject var controller: VisualizerController
    @ObservedObject var player: PlayerEngine
    @State private var settings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label(controller.useMilkDrop ? "MilkDrop" : "Cover Flow", systemImage: "waveform.path").font(.system(size: 13, weight: .semibold))
                Divider().frame(height: 18)
                Button { controller.step(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous preset (←)").accessibilityLabel("Previous preset")
                Menu {
                    if !controller.useMilkDrop {
                        ForEach(VisualizerStyle.allCases) { style in
                            Button(style.title) { controller.style = style }
                        }
                    } else {
                    ForEach(controller.presets) { preset in
                        Button { controller.choose(preset) } label: {
                            if preset == controller.selected { Label(preset.name, systemImage: "checkmark") }
                            else { Text(preset.name) }
                        }
                    }
                    Divider()
                    Button("Add MilkDrop Presets…") { controller.importPresets() }
                    }
                    Divider()
                    Button(controller.useMilkDrop ? "Use Metal Visualizer" : "Use MilkDrop Presets") { controller.useMilkDrop.toggle() }
                } label: { Text(controller.useMilkDrop ? (controller.selected?.name ?? "Choose a preset") : controller.style.title).lineLimit(1) }
                .frame(maxWidth: 280)
                Button { controller.step(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next preset (→)").accessibilityLabel("Next preset")
                Spacer(minLength: 8)
                Button { settings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Visualizer settings")
                    .popover(isPresented: $settings) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Visualizer").font(.headline)
                            Picker("Engine", selection: $controller.useMilkDrop) {
                                Text("Metal").tag(false); Text("MilkDrop").tag(true)
                            }
                            if !controller.useMilkDrop {
                                HStack {
                                    Text("Response")
                                    Slider(value: $controller.response, in: 0.5...2.5).accessibilityLabel("Music response")
                                }
                                Picker("Quality", selection: $controller.highQuality) {
                                    Text("High · 60 fps").tag(true); Text("Balanced · 30 fps").tag(false)
                                }
                                Text("Response changes the animation, never your playback volume.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(20).frame(width: 320)
                    }
                Toggle("Auto", isOn: $controller.automatic).toggleStyle(.switch).controlSize(.small)
                    .help("Change presets every 25 seconds while music plays")
                Button { controller.toggleFullScreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Full screen (Escape to return)").accessibilityLabel("Full screen")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            ZStack {
                if controller.useMilkDrop {
                    MilkDropSurface(controller: controller)
                } else {
                    NativeVisualizerSurface(audio: player.visualizerAudio,
                        playing: player.isPlaying && !player.isBuffering, style: controller.style,
                        response: Float(controller.response), highQuality: controller.highQuality,
                        onError: { controller.error = $0 })
                        .accessibilityLabel("Music visualizer reacting to bass, mids and treble")
                }
                if let error = controller.error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.title2)
                        Text(error).font(.callout).multilineTextAlignment(.center)
                        if !controller.useMilkDrop { Button("Use MilkDrop") { controller.useMilkDrop = true } }
                    }
                    .padding(24).frame(maxWidth: 480).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 16) {
                Button { player.previous() } label: { Image(systemName: "backward.fill") }.accessibilityLabel("Previous track")
                Button { player.togglePlayPause() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play").help("Play or pause (Space)")
                Button { player.next() } label: { Image(systemName: "forward.fill") }.accessibilityLabel("Next track")
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.currentTrack?.title ?? "Play some music to bring the visualizer to life")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let track = player.currentTrack { Text(track.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Text(player.isPlaying ? "" : "Paused").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(Color.black).preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                controller.tick()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
}
