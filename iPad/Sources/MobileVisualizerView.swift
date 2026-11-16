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
  @State private var fullScreen = false
  @FocusState private var keyboardFocus: Bool
  private var style: VisualizerStyle { VisualizerStyle(rawValue: styleID) ?? .pulse }
  var body: some View {
    VStack(spacing: 0) {
      ViewThatFits(in: .horizontal) {
        HStack {
          stylePicker.pickerStyle(.segmented).frame(minWidth: 300, maxWidth: 420)
          Spacer()
          visualizerControls
        }
        VStack(alignment: .leading, spacing: 8) {
          stylePicker.pickerStyle(.menu)
          HStack {
            visualizerControls
            Spacer()
          }
        }
      }.padding()
      ZStack {
        NativeVisualizerSurface(
          audio: player.visualizerAudio,
          playing: player.isPlaying && !player.isBuffering, style: style,
          response: Float(response), highQuality: highQuality, onError: { error = $0 })
        if let error {
          Text(error).multilineTextAlignment(.center).padding().background(
            .regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
      }.accessibilityLabel("Visualizer reacting to bass, mids and treble")
      if !player.hasTrack {
        Text("Play a track to see its sound.").font(.caption).foregroundStyle(.secondary).padding()
      }
    }
    .focusable().focused($keyboardFocus).focusEffectDisabled()
    // ← / → change styles, as on the Mac.
    .onKeyPress(.leftArrow) {
      changeStyle(-1)
      return .handled
    }
    .onKeyPress(.rightArrow) {
      changeStyle(1)
      return .handled
    }
    .fullScreenCover(isPresented: $fullScreen) {
      MobileVisualizerFullScreen(styleID: $styleID, response: response, highQuality: highQuality)
    }
    .onChange(of: styleID) { _, _ in lastChange = Date() }
    .task(id: reduceMotion) {
      player.visualizerAudio.setEnabled(true)
      while !Task.isCancelled {
        if auto, !reduceMotion, player.isPlaying, Date().timeIntervalSince(lastChange) > 25 {
          styleID = (style.rawValue + 1) % VisualizerStyle.allCases.count
          lastChange = Date()
        }
        do { try await Task.sleep(for: .seconds(1)) } catch { break }
      }
      player.visualizerAudio.setEnabled(false)
    }
  }
  private var stylePicker: some View {
    Picker("Visualizer style", selection: $styleID) {
      ForEach(VisualizerStyle.allCases) { Text($0.title).tag($0.rawValue) }
    }
  }
  @ViewBuilder private var visualizerControls: some View {
    Button {
      settings = true
    } label: {
      Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
    }.accessibilityLabel("Visualizer settings")
      .popover(isPresented: $settings) {
        VStack(alignment: .leading, spacing: 18) {
          Text("Music Response").font(.headline)
          Slider(value: $response, in: 0.5...2.5).accessibilityLabel("Music response")
          Toggle("High quality · 60 fps", isOn: $highQuality)
          Text("Changes the animation, never your playback volume.").font(.caption).foregroundStyle(
            .secondary)
        }.padding(24).frame(idealWidth: 300, maxWidth: 340)
      }
    Toggle("Auto", isOn: $auto).toggleStyle(.button)
    Button {
      fullScreen = true
    } label: {
      Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
    }.accessibilityLabel("Full screen")
    Button {
      player.togglePlayPause()
    } label: {
      Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
    }.accessibilityLabel("Play or pause")
  }

  private func changeStyle(_ delta: Int) {
    let count = VisualizerStyle.allCases.count
    styleID = ((style.rawValue + delta) % count + count) % count
  }
}

/// The visualizer filling the display. Tap for controls; Escape or Done closes.
struct MobileVisualizerFullScreen: View {
  @Binding var styleID: Int
  let response: Double
  let highQuality: Bool
  @EnvironmentObject private var player: PlayerEngine
  @Environment(\.dismiss) private var dismiss
  @State private var controls = true
  @State private var error: String?
  @FocusState private var focused: Bool
  private var style: VisualizerStyle { VisualizerStyle(rawValue: styleID) ?? .pulse }
  var body: some View {
    NativeVisualizerSurface(
      audio: player.visualizerAudio, playing: player.isPlaying && !player.isBuffering,
      style: style, response: Float(response), highQuality: highQuality, onError: { error = $0 }
    )
    .ignoresSafeArea()
    .contentShape(Rectangle())
    .onTapGesture { withAnimation { controls.toggle() } }
    .overlay(alignment: .top) {
      if controls {
        HStack {
          Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
          Spacer()
          Text(style.title).font(.headline)
          Spacer()
          Button {
            player.togglePlayPause()
          } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
          }.buttonStyle(.bordered).accessibilityLabel("Play or pause")
        }.padding().background(.ultraThinMaterial).transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .overlay {
      if let error { Text(error).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
    }
    .statusBarHidden(!controls)
    .persistentSystemOverlays(.hidden)
    .focusable().focused($focused).focusEffectDisabled()
    .onAppear { focused = true }
    .onKeyPress(.escape) {
      dismiss()
      return .handled
    }
    .onKeyPress(.space) {
      player.togglePlayPause()
      return .handled
    }
    .onKeyPress(.leftArrow) {
      styleID = (style.rawValue + VisualizerStyle.allCases.count - 1) % VisualizerStyle.allCases.count
      return .handled
    }
    .onKeyPress(.rightArrow) {
      styleID = (style.rawValue + 1) % VisualizerStyle.allCases.count
      return .handled
    }
    .task {
      // The presenting tab may stop analysis when it is covered; keep it on while shown.
      while !Task.isCancelled {
        player.visualizerAudio.setEnabled(true)
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
}
