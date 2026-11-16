import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Stem files prepared by Cover Flow on the Mac.
enum MobileStemFiles {
  /// Matches chosen WAV files (or the WAVs inside a chosen folder) to stems by name:
  /// `vocals.wav`, `instrumental.wav`, `drums.wav`, `bass.wav`, `guitar.wav`,
  /// `piano.wav`, `other.wav`. Names containing "vocal" or "instrumental" also match.
  /// The caller keeps the chosen URLs' security scope open until the import finishes.
  static func match(_ urls: [URL]) -> [AudioStem: URL] {
    var files: [URL] = []
    for url in urls {
      if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        let children =
          (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        files += children
      } else {
        files.append(url)
      }
    }
    var result: [AudioStem: URL] = [:]
    for file in files where file.pathExtension.lowercased() == "wav" {
      let name = file.deletingPathExtension().lastPathComponent.lowercased()
      let stem =
        AudioStem(rawValue: name)
        ?? (name.contains("instrumental")
          ? .instrumental : name.contains("vocal") ? .vocals : nil)
      if let stem, result[stem] == nil { result[stem] = file }
    }
    return result
  }

  /// Sums stereo 44.1 kHz stems into one Float32 WAV, in bounded chunks.
  static func mix(_ sources: [URL], to destination: URL) throws {
    guard !sources.isEmpty,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)
    else { throw NativeKaraokeError.message("Choose the instrument stems to mix.") }
    let inputs = try sources.map { try AVAudioFile(forReading: $0, commonFormat: .pcmFormatFloat32, interleaved: false) }
    guard let length = inputs.first?.length,
      inputs.allSatisfy({ $0.length == length && $0.fileFormat.sampleRate == 44100 && $0.fileFormat.channelCount == 2 })
    else {
      throw NativeKaraokeError.message("The stems must be stereo 44.1 kHz audio of the same length.")
    }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let output = try AVAudioFile(
      forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32,
      interleaved: false)
    let chunk: AVAudioFrameCount = 65_536
    guard let sum = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
      let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)
    else { throw NativeKaraokeError.message("Not enough memory to mix the stems.") }
    var remaining = length
    while remaining > 0 {
      let frames = AVAudioFrameCount(min(Int64(chunk), remaining))
      sum.frameLength = frames
      for channel in 0..<2 { sum.floatChannelData![channel].update(repeating: 0, count: Int(frames)) }
      for input in inputs {
        part.frameLength = 0
        try input.read(into: part, frameCount: frames)
        guard part.frameLength == frames else {
          throw NativeKaraokeError.message("A stem ended early. Prepare the track again on the Mac.")
        }
        for channel in 0..<2 {
          let target = sum.floatChannelData![channel]
          let source = part.floatChannelData![channel]
          for index in 0..<Int(frames) { target[index] += source[index] }
        }
      }
      try output.write(from: sum)
      remaining -= Int64(frames)
    }
  }
}

/// Instrument isolation buttons, like the icons under the Mac's microphone buttons.
/// Shown when the current track has a Demucs stem set.
struct MobileStemButtons: View {
  @EnvironmentObject private var player: PlayerEngine
  @EnvironmentObject private var karaoke: MobileKaraokeStore
  @State private var mixing = false
  /// A Demucs model that can prepare instrument stems: the selected one, or another added one.
  private var demucs: MobileKaraokeModel? {
    if let selected = karaoke.selected, selected.backend == .demucs { return selected }
    return karaoke.models.last { $0.backend == .demucs }
  }
  private var instruments: [AudioStem] {
    let prepared = (karaoke.audio?.availableStems ?? []).filter {
      $0 != .vocals && $0 != .instrumental
    }
    if !prepared.isEmpty { return prepared }
    // Not prepared yet: offer the Demucs model's stems; tapping one prepares them all.
    return (demucs?.stems ?? []).compactMap(AudioStem.init(rawValue:)).filter {
      $0 != .vocals && $0 != .instrumental
    }
  }
  var body: some View {
    if !instruments.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Isolate").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(instruments) { stem in
              let mode = KaraokePlayback(rawValue: stem.rawValue) ?? .original
              Button {
                select(player.karaokePlayback == mode ? .original : mode)
              } label: {
                Image(systemName: stem.symbol).frame(width: 40, height: 40)
                  .background(
                    player.karaokePlayback == mode ? MobilePalette.brass.opacity(0.22) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
              }
              .accessibilityLabel(player.karaokePlayback == mode ? "Original audio" : "Only \(stem.title)")
              .accessibilityValue(player.karaokePlayback == mode ? "Selected" : "")
            }
            if karaoke.processing {
              ProgressView(value: karaoke.progress).frame(width: 60)
            }
            Divider().frame(height: 28)
            Button {
              mixing = true
            } label: {
              Label("Stem Mix", systemImage: "slider.horizontal.3").padding(.horizontal, 4)
                .frame(height: 40)
            }.tint(player.karaokePlayback == .mix ? MobilePalette.brass : nil)
          }.buttonStyle(.bordered)
        }.scrollIndicators(.hidden)
      }
      .sheet(isPresented: $mixing) {
        NavigationStack { MobileStemMixView().navigationTitle("Stem Mix").toolbar {
          ToolbarItem(placement: .confirmationAction) { Button("Done") { mixing = false } }
        } }.presentationDetents([.medium, .large])
      }
    }
  }
  private func select(_ mode: KaraokePlayback) {
    guard let track = player.currentTrack else { return }
    // Like the Mac: an instrument choice switches to Demucs when needed, then
    // prepares every stem and plays the chosen one from the current position.
    if mode != .original, karaoke.audio?.availableStems.contains(where: { $0.rawValue == mode.rawValue }) != true,
      let demucs, karaoke.selectedID != demucs.id
    {
      karaoke.select(demucs.id, player: player)
    }
    let engine = player
    karaoke.request(mode, track: track) { [weak engine] mode, audio in
      guard let engine, engine.currentTrackID == track.id else { return }
      if engine.karaokePlayback != mode { engine.setKaraokePlayback(mode, audio: audio) }
    }
  }
}

/// Live levels, mute, multi-solo, reset and export for every stem of the current track.
struct MobileStemMixView: View {
  @EnvironmentObject private var player: PlayerEngine
  @EnvironmentObject private var karaoke: MobileKaraokeStore
  var body: some View {
    Form {
      if let audio = karaoke.audio, audio.availableStems.count > 2 {
        Section {
          ForEach(audio.availableStems) { stem in row(stem) }
        } footer: {
          Text("Moving a slider starts the mix; later changes are immediate. Solo several stems to hear them together.")
        }
        Section {
          Button(player.karaokePlayback == .mix ? "Stem Mix Selected" : "Use Stem Mix") { activate() }
            .disabled(!player.hasTrack || player.karaokePlayback == .mix)
          Button("Reset Levels") { player.setStemMix(StemMixSettings()) }
          Button("Original Audio") { player.setKaraokePlayback(.original) }
            .disabled(player.karaokePlayback == .original)
        }
        Section("Export") {
          ForEach(audio.availableStems) { stem in
            if let url = audio.stemFiles[stem] {
              ShareLink(item: url) { Label("\(stem.title) WAV", systemImage: stem.symbol) }
            }
          }
          ShareLink(items: audio.availableStems.compactMap { audio.stemFiles[$0] } + [audio.instrumental]) {
            Label("All Stems", systemImage: "square.and.arrow.up.on.square")
          }
        }
      } else {
        ContentUnavailableView {
          Label("No stems for this track", systemImage: "slider.horizontal.3")
        } description: {
          Text(
            "Prepare the track with Demucs in Cover Flow on your Mac, then choose Karaoke → Add → Import Prepared Stems… and select the stem files or their folder."
          )
        }
      }
    }
    .onChange(of: player.currentTrackID) { _, _ in player.setStemMix(StemMixSettings()) }
  }
  private func row(_ stem: AudioStem) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label(stem.title, systemImage: stem.symbol)
        Spacer()
        Button {
          change { mix in if !mix.muted.insert(stem).inserted { mix.muted.remove(stem) } }
        } label: {
          Image(systemName: player.stemMix.muted.contains(stem) ? "speaker.slash.fill" : "speaker.wave.2")
            .frame(width: 36, height: 36)
        }.accessibilityLabel("Mute \(stem.title)")
          .accessibilityValue(player.stemMix.muted.contains(stem) ? "On" : "Off")
        Button {
          change { mix in if !mix.solo.insert(stem).inserted { mix.solo.remove(stem) } }
        } label: {
          Text("S").font(.subheadline.weight(.bold)).frame(width: 36, height: 36)
            .foregroundStyle(player.stemMix.solo.contains(stem) ? MobilePalette.brass : .secondary)
        }.accessibilityLabel("Solo \(stem.title)")
          .accessibilityValue(player.stemMix.solo.contains(stem) ? "On" : "Off")
      }.buttonStyle(.borderless)
      HStack {
        Slider(
          value: Binding(
            get: { Double(player.stemMix.levels[stem] ?? 1) },
            set: { value in change { $0.levels[stem] = Float(value) } }), in: 0...1
        ).accessibilityLabel("\(stem.title) level")
        Text("\(Int(((player.stemMix.levels[stem] ?? 1) * 100).rounded()))%")
          .font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
      }
    }.opacity(player.stemMix.gain(stem) == 0 ? 0.55 : 1)
  }
  private func change(_ update: (inout StemMixSettings) -> Void) {
    var mix = player.stemMix
    update(&mix)
    player.setStemMix(mix)
    activate()
  }
  private func activate() {
    guard player.karaokePlayback != .mix, let audio = karaoke.audio else { return }
    player.setKaraokePlayback(.mix, audio: audio)
  }
}
