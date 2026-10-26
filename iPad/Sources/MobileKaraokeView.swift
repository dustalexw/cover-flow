import SwiftUI
import UniformTypeIdentifiers

struct MobileKaraokeView: View {
  @EnvironmentObject private var karaoke: MobileKaraokeStore
  @EnvironmentObject private var player: PlayerEngine
  @State private var importModel = false
  @State private var importSettings = false
  @State private var importStems = false
  @State private var modelBusy = false
  @State private var stagedModel: URL?
  @State private var offerSettings = false
  @State private var removeModel = false
  @State private var stemTrack: Track?
  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("Karaoke", systemImage: "mic.fill").font(.title2.weight(.semibold))
          Spacer()
          if modelBusy || karaoke.importingModel { ProgressView() }
          Menu {
            Button("Add Model…", systemImage: "plus") { importModel = true }
            Button("Import Prepared Stems…", systemImage: "square.and.arrow.down") {
              stemTrack = player.currentTrack
              importStems = true
            }.disabled(!player.hasTrack)
            if karaoke.selected != nil {
              Button("Remove Selected Model", systemImage: "trash", role: .destructive) {
                removeModel = true
              }
            }
          } label: {
            Label("Add", systemImage: "plus")
          }.disabled(karaoke.processing || karaoke.importingModel || modelBusy)
        }
        if !karaoke.models.isEmpty || karaoke.audio != nil {
          Picker(
            "Model",
            selection: Binding<UUID?>(
              get: { karaoke.selectedID }, set: { karaoke.select($0, player: player) })
          ) {
            Text("Imported Stems").tag(nil as UUID?)
            ForEach(karaoke.models) { Text($0.name).tag(Optional($0.id)) }
          }.pickerStyle(.menu).disabled(karaoke.processing || karaoke.importingModel || modelBusy)
        }
        if karaoke.selected != nil {
          Text(
            karaoke.selected?.backend == .mdx
              ? "MDX · Core ML GPU preferred · CPU fallback" : "Converted waveform model · Core ML"
          ).font(.caption).foregroundStyle(.secondary)
        } else if karaoke.audio != nil {
          Text("Imported prepared stems").font(.caption).foregroundStyle(.secondary)
        } else {
          Text(
            "Add an MDX ONNX model such as Inst_HQ_5, a converted Core ML model, or prepared stems from Cover Flow on your Mac."
          ).font(.subheadline).foregroundStyle(.secondary)
        }
        if karaoke.processing {
          VStack(alignment: .leading, spacing: 6) {
            if let title = karaoke.processingTitle {
              Text("Preparing \(title)").font(.caption.weight(.medium)).fixedSize(
                horizontal: false, vertical: true)
            }
            ProgressView(value: karaoke.progress)
            HStack {
              Text(karaoke.stage).font(.caption)
              Spacer()
              Button(karaoke.cancelling ? "Cancelling…" : "Cancel") { karaoke.cancel() }.disabled(
                karaoke.cancelling)
            }
          }
        } else if karaoke.audio != nil {
          HStack {
            Label("Prepared audio ready", systemImage: "checkmark.circle.fill").foregroundStyle(
              .green)
            Spacer()
            if let audio = karaoke.audio {
              Menu {
                ShareLink(item: audio.instrumental) { Text("Instrumental WAV") }
                ShareLink(item: audio.vocals) { Text("Vocals WAV") }
              } label: {
                Label("Export", systemImage: "square.and.arrow.up")
              }
            }
          }.font(.subheadline)
        }
        if let error = karaoke.error {
          Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) {
            modes
            Spacer()
            prepare
          }
          VStack(alignment: .leading, spacing: 10) {
            modes
            prepare
          }
        }
        Text(
          "Keep Cover Flow open during preparation. Switching sources keeps your playback position; models have separate saved audio."
        ).font(.caption2).foregroundStyle(.secondary)
      }.padding(20)
      Divider()
      MobileLyricsView()
    }
    .confirmationDialog(
      "Remove this imported model and its prepared audio?", isPresented: $removeModel,
      titleVisibility: .visible
    ) { Button("Remove Model", role: .destructive) { karaoke.removeSelected(player: player) } }
    .fileImporter(
      isPresented: $importModel,
      allowedContentTypes: ["onnx", "mlmodel", "mlpackage", "mlmodelc"].map {
        UTType(filenameExtension: $0) ?? .data
      }
    ) { result in
      guard case .success(let url) = result else {
        if case .failure(let error) = result { karaoke.error = error.localizedDescription }
        return
      }
      Task { await addModel(url) }
    }
    .confirmationDialog(
      "This model needs its matching UVR JSON settings.", isPresented: $offerSettings,
      titleVisibility: .visible
    ) {
      Button("Choose JSON Settings…") { importSettings = true }
      Button("Cancel", role: .cancel) { cleanupStage() }
    }
    .fileImporter(isPresented: $importSettings, allowedContentTypes: [.json]) { result in
      guard case .success(let settings) = result, let stagedModel else {
        cleanupStage()
        return
      }
      Task {
        modelBusy = true
        defer {
          modelBusy = false
          cleanupStage()
        }
        do {
          try await karaoke.importModel(stagedModel, settings: settings)
          player.setKaraokePlayback(.original)
        } catch { karaoke.error = error.localizedDescription }
      }
    }
    .fileImporter(
      isPresented: $importStems, allowedContentTypes: [.wav], allowsMultipleSelection: true
    ) { result in
      guard case .success(let files) = result, let track = stemTrack else { return }
      guard files.count == 2,
        let vocals = files.first(where: { $0.lastPathComponent.lowercased().contains("vocal") }),
        let music = files.first(where: {
          $0.lastPathComponent.lowercased().contains("instrumental")
        }), vocals != music
      else {
        karaoke.error =
          "Select two files named vocals.wav and instrumental.wav from the same prepared track."
        return
      }
      Task {
        do {
          try await karaoke.importStems(vocals: vocals, instrumental: music, track: track)
          if player.currentTrackID == track.id { player.setKaraokePlayback(.original) }
        } catch { karaoke.error = error.localizedDescription }
      }
    }
    .onDisappear { if !offerSettings && !importSettings { cleanupStage() } }
  }
  private var modes: some View {
    HStack(spacing: 6) {
      ForEach(Array([KaraokePlayback.original, .instrumental, .vocals].enumerated()), id: \.element.id) { index, mode in
        Button {
          guard let track = player.currentTrack else { return }
          let engine = player
          karaoke.request(mode, track: track) { [weak engine] mode, audio in
            guard let engine, engine.currentTrackID == track.id else { return }
            if engine.karaokePlayback != mode { engine.setKaraokePlayback(mode, audio: audio) }
          }
        } label: {
          Text(mode.title).font(.caption.weight(.medium)).padding(.vertical, 3)
        }
        .buttonStyle(.bordered).tint(
          player.karaokePlayback == mode ? MobilePalette.brass : .secondary
        )
        .disabled(!player.hasTrack).keyboardShortcut(
          KeyEquivalent(Character(String(index + 1))), modifiers: [])
      }
    }
  }
  private var prepare: some View {
    Button("Prepare") { if let track = player.currentTrack { karaoke.prepare(track) } }.buttonStyle(
      .borderedProminent
    ).disabled(
      !player.hasTrack || karaoke.selected == nil || karaoke.processing || karaoke.importingModel
        || karaoke.audio != nil
    ).keyboardShortcut("p", modifiers: [])
  }
  private func addModel(_ url: URL) async {
    modelBusy = true
    defer { modelBusy = false }
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ModelImport-" + UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let copy = folder.appendingPathComponent(url.lastPathComponent)
      try await Task.detached(priority: .userInitiated) {
        try LibraryStore.coordinated(url) { try FileManager.default.copyItem(at: $0, to: copy) }
      }.value
      cleanupStage()
      stagedModel = copy
      do {
        try await karaoke.importModel(copy)
        player.setKaraokePlayback(.original)
        cleanupStage()
      } catch NativeKaraokeError.needsMDXSettings { offerSettings = true } catch {
        karaoke.error = error.localizedDescription
        cleanupStage()
      }
    } catch {
      karaoke.error = error.localizedDescription
      try? FileManager.default.removeItem(at: folder)
    }
  }
  private func cleanupStage() {
    if let stagedModel {
      try? FileManager.default.removeItem(at: stagedModel.deletingLastPathComponent())
    }
    stagedModel = nil
  }
}
