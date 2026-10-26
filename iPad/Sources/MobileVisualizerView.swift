import SwiftUI

struct MobileVisualizerView: View {
  @EnvironmentObject private var player: PlayerEngine
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage("visualizer.style") private var styleID = 0
  @AppStorage("visualizer.response") private var response = 1.25
  @AppStorage("visualizer.highQuality") private var highQuality = true
  @State private var auto = true
  @State private var settings = false
  @State private var error: String?
  @State private var lastChange = Date()
  private var style: VisualizerStyle { VisualizerStyle(rawValue: styleID) ?? .pulse }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("Visualizer", selection: $styleID) {
          ForEach(VisualizerStyle.allCases) { style in Text(style.title).tag(style.rawValue) }
        }.pickerStyle(.segmented).frame(maxWidth: 420)
        Spacer()
        Button { settings = true } label: {
          Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
        }.accessibilityLabel("Visualizer settings")
        .popover(isPresented: $settings) {
          VStack(alignment: .leading, spacing: 18) {
            Text("Music Response").font(.headline)
            Slider(value: $response, in: 0.5...2.5).accessibilityLabel("Music response")
            Toggle("High quality · 60 fps", isOn: $highQuality)
            Text("Changes the animation, never your playback volume.").font(.caption).foregroundStyle(.secondary)
          }.padding(24).frame(width: 300)
        }
        Toggle("Auto", isOn: $auto).toggleStyle(.button)
        Button { player.togglePlayPause() } label: {
          Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
        }.accessibilityLabel("Play or pause")
      }.padding()
      ZStack {
        NativeVisualizerSurface(audio: player.visualizerAudio,
          playing: player.isPlaying && !player.isBuffering, style: style,
          response: Float(response), highQuality: highQuality, onError: { error = $0 })
        if let error { Text(error).multilineTextAlignment(.center).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
      }.accessibilityLabel("Visualizer reacting to bass, mids and treble")
      if !player.hasTrack { Text("Play a track to see its sound.").font(.caption).foregroundStyle(.secondary).padding() }
    }
    .onChange(of: styleID) { _, _ in lastChange = Date() }
    .task(id: reduceMotion) {
      player.visualizerAudio.setEnabled(true)
      while !Task.isCancelled {
        if auto, !reduceMotion, player.isPlaying, Date().timeIntervalSince(lastChange) > 25 {
          styleID = (style.rawValue + 1) % VisualizerStyle.allCases.count; lastChange = Date()
        }
        do { try await Task.sleep(for: .seconds(1)) } catch { break }
      }
      player.visualizerAudio.setEnabled(false)
    }
  }
}
