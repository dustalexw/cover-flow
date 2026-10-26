import SwiftUI

struct KaraokeView: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var karaoke: KaraokeStore
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Karaoke", systemImage: "mic.fill").font(.system(size: 24, weight: .semibold))
                    Spacer()
                    Button("Add model…") {
                        let previous = karaoke.model
                        karaoke.chooseModel()
                        if karaoke.model != previous { player.setKaraokePlayback(.original) }
                    }
                        .disabled(karaoke.isProcessing)
                }
                if !karaoke.models.isEmpty {
                    Picker("Model", selection: Binding(get: { karaoke.model?.id ?? "" }, set: { player.setKaraokePlayback(.original); player.setStemMix(StemMixSettings()); karaoke.selectModel(id: $0) })) {
                        ForEach(karaoke.models) { model in
                            Text(model.title).tag(model.id).help(model.checkpoint.path)
                        }
                    }
                    .pickerStyle(.menu).disabled(karaoke.isProcessing)
                    .accessibilityLabel("Karaoke model")
                }
                Text(karaoke.model?.kind.title ?? "Add a UVR MDX ONNX or Mel-Band RoFormer model to prepare karaoke.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    .help(karaoke.model?.checkpoint.path ?? "")
                if karaoke.model?.checkpoint.lastPathComponent == "htdemucs_6s.demucs" {
                    Text("Guitar and piano separation is experimental; some instruments may bleed into other stems.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if karaoke.isProcessing {
                    Text("Finish or cancel preparation to switch models.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if karaoke.isProcessing {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            ScrollingTrackTitle("Preparing \(karaoke.processingTitle ?? "track")").font(.system(size: 13, weight: .medium))
                            Text(karaoke.stage).font(.system(size: 12)).foregroundStyle(.secondary)
                            ProgressView(value: karaoke.progress)
                        }
                        Button("Cancel") { karaoke.cancel() }
                    }
                } else if let track = player.currentTrack {
                    HStack {
                        if karaoke.audio != nil {
                            Label("Karaoke audio ready", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 13)).foregroundStyle(Palette.accent(scheme))
                        } else {
                            Text("Prepare this track once, then switch to its instrumental.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if karaoke.audio != nil {
                            Button("Export instrumental…") { karaoke.exportInstrumental(title: track.title) }
                        }
                    }
                } else {
                    Text("Play or select a track in Cover Flow to prepare karaoke.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if karaoke.audio != nil {
                    Text("Karaoke plays the instrumental. Vocals plays the separated voice. Switching keeps your playback position.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let error = karaoke.errorMessage {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                }
            }.padding(20)
            Divider()
            StemMixView()
            Divider()
            LyricsView(playbackActions: AnyView(playbackActions))
        }
        .background(Palette.base(scheme)).tint(Palette.accent(scheme))
        .preferredColorScheme(state.colorScheme)
        .onChange(of: player.currentTrackID, initial: true) { karaoke.refresh(for: player.currentTrack) }

    }

    private var playbackActions: some View {
        HStack(spacing: 6) {
            ForEach(Array([KaraokePlayback.original, .instrumental, .vocals].enumerated()), id: \.element.id) { index, mode in
                Button { selectPlayback(mode) } label: {
                    HStack(spacing: 4) {
                        Text(mode.title)
                        shortcutBadge(String(index + 1))
                    }
                }
                .tint(player.karaokePlayback == mode ? Palette.accent(scheme) : .secondary)
                .disabled(!player.hasTrack || (mode != .original && karaoke.audio == nil))
                .help("\(mode.title) (\(index + 1))")
                .accessibilityValue(player.karaokePlayback == mode ? "Selected" : "")
            }
            Button {
                if let track = player.currentTrack { karaoke.prepare(track) }
            } label: {
                HStack(spacing: 4) {
                    Text("Prepare")
                    shortcutBadge("P")
                }
            }
            .disabled(!player.hasTrack || karaoke.model == nil || karaoke.isProcessing || karaoke.audio != nil)
            .help("Prepare karaoke (P)").accessibilityLabel("Prepare karaoke")
        }
        .buttonStyle(.bordered).controlSize(.small).font(.system(size: 11, weight: .medium))
    }

    private func shortcutBadge(_ key: String) -> some View {
        Text(key).font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary).padding(.horizontal, 3).padding(.vertical, 1)
            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
            .accessibilityHidden(true)
    }

    private func selectPlayback(_ mode: KaraokePlayback) {
        guard let track = player.currentTrack else { return }
        karaoke.requestPlayback(mode, for: track) { [weak player] mode, audio in
            guard let player, player.currentTrackID == track.id else { return }
            if player.karaokePlayback != mode { player.setKaraokePlayback(mode, audio: audio) }
        }
    }
}
