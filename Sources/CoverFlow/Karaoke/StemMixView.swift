import SwiftUI

struct StemMixView: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var karaoke: KaraokeStore
    @Environment(\.colorScheme) private var scheme
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let audio = karaoke.audio {
                VStack(spacing: 10) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(audio.availableStems) { stem in row(stem) }
                    }
                    HStack {
                        Button(player.karaokePlayback == .mix ? "Stem Mix Selected" : "Use Stem Mix") { activate() }
                            .buttonStyle(.borderedProminent).disabled(!player.hasTrack)
                        Button("Reset") { player.setStemMix(StemMixSettings()) }
                        Spacer()
                        Menu("Export stem…") {
                            ForEach(audio.availableStems) { stem in
                                Button(stem.title) { karaoke.exportStem(stem, title: player.currentTrack?.title ?? "Track") }
                            }
                            Divider()
                            Button("All stems…") { karaoke.exportAllStems(title: player.currentTrack?.title ?? "Track") }
                        }.menuStyle(.borderlessButton).fixedSize()
                    }.controlSize(.small)
                }.padding(.top, 10)
            } else {
                HStack {
                    Text("Separate a track to adjust each instrument. Choose Demucs 6 stems for guitar and piano.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Prepare stems") {
                        guard let track = player.currentTrack else { return }
                        if let six = karaoke.models.first(where: { $0.checkpoint.lastPathComponent == "htdemucs_6s.demucs" }) {
                            karaoke.selectModel(id: six.id)
                        }
                        karaoke.prepare(track)
                    }.disabled(!player.hasTrack || karaoke.isProcessing)
                }.padding(.top, 8)
            }
        } label: {
            Label("Stem Mix", systemImage: "slider.horizontal.3").font(.system(size: 14, weight: .semibold))
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Palette.raised(scheme).opacity(0.6))
        .onChange(of: player.currentTrackID) { player.setStemMix(StemMixSettings()) }
        .onChange(of: karaoke.model) { player.setStemMix(StemMixSettings()) }
    }

    private func row(_ stem: AudioStem) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                Label(stem.title, systemImage: stem.symbol).font(.system(size: 11, weight: .medium))
                Spacer(minLength: 2)
                Button { change { mix in
                    if !mix.muted.insert(stem).inserted { mix.muted.remove(stem) }
                } } label: { Image(systemName: player.stemMix.muted.contains(stem) ? "speaker.slash.fill" : "speaker.wave.2") }
                    .help("Mute \(stem.title)")
                    .accessibilityLabel("Mute \(stem.title)")
                    .accessibilityValue(player.stemMix.muted.contains(stem) ? "On" : "Off")
                Button { change { mix in
                    if !mix.solo.insert(stem).inserted { mix.solo.remove(stem) }
                } } label: {
                    Text("S").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(player.stemMix.solo.contains(stem) ? Palette.accent(scheme) : .secondary)
                }.help("Solo \(stem.title)").accessibilityLabel("Solo \(stem.title)")
                    .accessibilityValue(player.stemMix.solo.contains(stem) ? "On" : "Off")
            }.buttonStyle(.borderless)
            HStack(spacing: 6) {
                Slider(value: Binding(get: { Double(player.stemMix.levels[stem] ?? 1) }, set: { value in
                    change { $0.levels[stem] = Float(value) }
                }), in: 0...1).accessibilityLabel("\(stem.title) level")
                Text("\(Int((player.stemMix.levels[stem] ?? 1) * 100))%")
                    .font(.system(size: 9, design: .monospaced)).monospacedDigit().frame(width: 30)
            }
        }.padding(8)
            .background(.primary.opacity(player.stemMix.gain(stem) == 0 ? 0.02 : 0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func change(_ update: (inout StemMixSettings) -> Void) {
        var mix = player.stemMix; update(&mix); player.setStemMix(mix); activate()
    }
    private func activate() {
        guard player.karaokePlayback != .mix, let audio = karaoke.audio else { return }
        player.setKaraokePlayback(.mix, audio: audio)
    }
}
