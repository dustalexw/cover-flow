import Accelerate
import SwiftUI

@MainActor final class MobileVisualizerSignal: ObservableObject {
  @Published var wave = [Float](repeating: 0, count: 256)
  @Published var bands = [Float](repeating: 0, count: 48)
  private let transform = vDSP.DFT(
    count: 1024, direction: .forward, transformType: .complexComplex, ofType: Float.self)!
  func update(_ audio: VisualizerAudioBuffer) {
    var buffer = [Float](repeating: 0, count: 4096)
    let frames = buffer.withUnsafeMutableBufferPointer { audio.drain(into: $0) }
    guard frames > 0 else {
      bands = bands.map { $0 * 0.9 }
      return
    }
    let mono = (0..<1024).map { index -> Float in
      let position = max(0, frames - 1024) + index
      return position < frames ? (buffer[position * 2] + buffer[position * 2 + 1]) * 0.5 : 0
    }
    wave = (0..<256).map { mono[$0 * 4] }
    let windowed = mono.enumerated().map { index, value in
      value * (0.5 - 0.5 * cos(2 * Float.pi * Float(index) / 1024))
    }
    let spectrum = transform.transform(
      inputReal: windowed, inputImaginary: [Float](repeating: 0, count: 1024))
    bands = (0..<48).map { band in
      let low = Int(pow(512, Double(band) / 48))
      let high = max(low + 1, Int(pow(512, Double(band + 1) / 48)))
      let energy =
        (low..<min(512, high)).map { hypot(spectrum.real[$0], spectrum.imaginary[$0]) }.max() ?? 0
      return max(bands[band] * 0.8, min(1, log10(1 + energy) * 0.65))
    }
  }
}
struct MobileVisualizerView: View {
  @EnvironmentObject private var player: PlayerEngine
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var signal = MobileVisualizerSignal()
  @State private var style = 0
  @State private var auto = true
  @State private var lastChange = Date()
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("Visualizer", selection: $style) {
          Text("Spectrum").tag(0)
          Text("Orbits").tag(1)
          Text("Ribbon").tag(2)
        }.pickerStyle(.segmented).frame(maxWidth: 420)
        Spacer()
        Toggle("Auto", isOn: $auto).toggleStyle(.button)
        Button {
          player.togglePlayPause()
        } label: {
          Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(
            width: 44, height: 44)
        }.accessibilityLabel("Play or pause")
      }.padding()
      Canvas { context, size in
        let colors: [Color] = [.cyan, MobilePalette.brass, .pink]
        if style == 0 {
          let width = size.width / CGFloat(signal.bands.count)
          for index in signal.bands.indices {
            let height = max(2, CGFloat(signal.bands[index]) * (size.height - 50))
            let rect = CGRect(
              x: CGFloat(index) * width + 2, y: size.height - height, width: max(1, width - 4),
              height: height)
            context.fill(
              Path(roundedRect: rect, cornerRadius: 3),
              with: .linearGradient(
                Gradient(colors: [colors[index % 3], colors[index % 3].opacity(0.1)]),
                startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: size.height)))
          }
        } else if style == 1 {
          let center = CGPoint(x: size.width / 2, y: size.height / 2)
          let radius = min(size.width, size.height) * 0.28
          for ring in 0..<3 {
            var path = Path()
            for index in 0...256 {
              let value = CGFloat(signal.wave[index % 256])
              let angle = CGFloat(index) / 256 * 2 * CGFloat.pi
              let r = radius + CGFloat(ring) * 24 + value * 90
              let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
              if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(colors[ring].opacity(0.8)), lineWidth: 2.5)
          }
        } else {
          for ribbon in 0..<3 {
            var path = Path()
            for index in signal.wave.indices {
              let point = CGPoint(
                x: CGFloat(index) / 255 * size.width,
                y: size.height / 2 + CGFloat(signal.wave[index]) * size.height * 0.55 + CGFloat(
                  ribbon - 1) * 30)
              if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(
              path, with: .color(colors[ribbon].opacity(0.85)),
              style: StrokeStyle(lineWidth: 3, lineCap: .round))
          }
        }
      }.background(MobilePalette.navy).accessibilityLabel(
        "Visualizer reacting to the playing audio")
      if !player.hasTrack {
        Text("Play a track to see its sound.").font(.caption).foregroundStyle(.secondary).padding()
      }
    }
    .task {
      player.visualizerAudio.setEnabled(true)
      while !Task.isCancelled {
        signal.update(player.visualizerAudio)
        if auto, !reduceMotion, Date().timeIntervalSince(lastChange) > 25 {
          style = (style + 1) % 3
          lastChange = Date()
        }
        do { try await Task.sleep(for: .milliseconds(reduceMotion ? 120 : 40)) } catch { break }
      }
      player.visualizerAudio.setEnabled(false)
    }
  }
}
