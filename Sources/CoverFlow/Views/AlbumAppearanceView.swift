import SwiftUI
import AppKit

/// A still image; resizing only crops it. There is no animation, parallax or audio input.
struct AlbumSceneBackground: View {
    let style: AlbumPanelStyle

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                style.colors.background.color
                if let scene = style.scene {
                    Image(decorative: scene, scale: 1)
                        .resizable().interpolation(.high)
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct AlbumAppearanceView: View {
    let albumID: UUID
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AlbumAppearance()
    @State private var automatic: AlbumDetailPalette?
    @State private var preview: AlbumPanelStyle?
    @State private var loaded = false
    @State private var colorsReady = false
    @State private var backgroundInput = ""
    @State private var textInput = ""
    @State private var accentInput = ""
    @State private var preparing = true

    private var album: Album? { library.album(albumID) }
    private var automaticColors: AlbumDetailPalette {
        automatic ?? album.map(AlbumDetailPalette.fallback) ?? AlbumDetailPalette(background: .black)
    }
    private var settings: AlbumAppearance {
        var result = draft
        guard colorsReady else { return result }
        result.backgroundHex = draft.backgroundHex == nil && backgroundInput == automaticColors.background.hex ? nil : backgroundInput
        result.textHex = draft.textHex == nil && textInput == automaticColors.foreground.hex ? nil : textInput
        result.accentHex = draft.accentHex == nil && accentInput == automaticColors.accent.hex ? nil : accentInput
        return result
    }
    private var previewKey: String { "\(album?.artworkKey ?? "none")|\(settings.key)" }
    private var validColors: Bool {
        colorsReady && [backgroundInput, textInput, accentInput].allSatisfy { AlbumDetailPalette.RGB(hex: $0) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Colors & Scene").font(.system(size: 23, weight: .semibold, design: .serif))
                Spacer()
                Text(album?.title ?? "Album").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    if let album {
                        AlbumAppearancePreview(album: album, tracks: Array(library.tracks(of: album).prefix(5)),
                                               style: preview ?? AlbumPanelStyle(colors: automaticColors.customized(settings), scene: nil))
                            .environmentObject(library)
                    }
                    HStack(spacing: 6) {
                        if preparing { ProgressView().controlSize(.small) }
                        Text(preparing ? (draft.sceneEnabled && draft.refinesScene && AlbumSceneRefiner.isAvailable
                                          ? "Refining scene with Stable Diffusion…" : "Preparing preview…")
                                       : "Preview of this album’s track panel")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("The scene stays still. It uses the cover’s shapes, textures, and colors, with a quieter area behind titles and tracks.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 520)

                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Colors") {
                        VStack(alignment: .leading, spacing: 13) {
                            if colorsReady, let automatic {
                                colorRow("Background", input: $backgroundInput, fallback: automatic.background)
                                colorRow("Text", input: $textInput, fallback: automatic.foreground)
                                colorRow("Accent", input: $accentInput, fallback: automatic.accent)
                            } else {
                                ProgressView("Reading cover colors…").controlSize(.small)
                            }
                            Text(validColors ? "Text and accent colors are adjusted when needed to keep them readable."
                                             : "Use a six-digit hex color, such as #183A4B.")
                                .font(.caption).foregroundStyle(validColors ? Color.secondary : Color.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                    }
                    GroupBox("Cover Scene") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Show generated scene", isOn: $draft.sceneEnabled)
                                .disabled(album?.hasArtwork != true)
                            HStack {
                                Text("Scene strength")
                                Spacer()
                                Text("\(Int(draft.strength * 100))%").monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12))
                            Slider(value: $draft.sceneStrength, in: 0...1)
                                .accessibilityLabel("Scene strength")
                                .disabled(!draft.sceneEnabled || album?.hasArtwork != true)
                            Button("Regenerate Scene") { draft.sceneVariation &+= 1 }
                                .disabled(!draft.sceneEnabled || album?.hasArtwork != true || preparing)
                            if AlbumSceneRefiner.isAvailable {
                                Toggle("Refine with Stable Diffusion", isOn: Binding(
                                    get: { draft.refinesScene },
                                    set: { draft.sceneRefinement = $0 }))
                                    .disabled(!draft.sceneEnabled || album?.hasArtwork != true)
                                Picker("Style", selection: Binding(
                                    get: { draft.style },
                                    set: { draft.refinementStyle = $0 })) {
                                    ForEach(SceneRefinementStyle.allCases) { Text($0.label).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .disabled(!draft.sceneEnabled || !draft.refinesScene || album?.hasArtwork != true)
                                Text(draft.style == .ornate
                                     ? "Ornate repaints the surroundings as decorative imagery that continues the cover."
                                     : "Subtle keeps the generated scene’s look and smooths it.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Runs on this Mac. The first refinement of an album takes about 10–40 seconds and is then saved.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if draft.sceneEnabled && draft.refinesScene && !preparing && preview?.scene != nil {
                                    if let note = preview?.refinementNote {
                                        Label("Couldn’t refine: \(note) Showing the regular scene.", systemImage: "exclamationmark.triangle")
                                            .font(.caption).foregroundStyle(.orange)
                                            .fixedSize(horizontal: false, vertical: true)
                                    } else {
                                        Label("Refined with Stable Diffusion.", systemImage: "checkmark.circle")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if album?.hasArtwork != true {
                                Text("Add album artwork to generate a scene.").font(.caption).foregroundStyle(.secondary)
                            } else if !preparing && draft.sceneEnabled && draft.strength > 0 && preview?.scene == nil {
                                Text("The cover could not be used for a scene. Replace the artwork and try again.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                    }
                    Button("Reset to Cover") {
                        draft = AlbumAppearance()
                        backgroundInput = automaticColors.background.hex
                        textInput = automaticColors.foreground.hex
                        accentInput = automaticColors.accent.hex
                    }
                        .help("Restore automatic cover colors and the original generated scene")
                }
                .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
            HStack {
                Text("Saved for this album’s track panel only.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard validColors else { return }
                    var saving = settings
                    saving.backgroundHex = saving.backgroundHex.flatMap { AlbumDetailPalette.RGB(hex: $0)?.hex }
                    saving.textHex = saving.textHex.flatMap { AlbumDetailPalette.RGB(hex: $0)?.hex }
                    saving.accentHex = saving.accentHex.flatMap { AlbumDetailPalette.RGB(hex: $0)?.hex }
                    library.updateAppearance(albumID, appearance: saving)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!validColors || album == nil)
            }
        }
        .padding(24)
        .frame(width: 920, height: 610)
        .onAppear {
            guard !loaded, let album else { return }
            draft = album.panelAppearance; loaded = true
        }
        .task(id: album?.artworkKey) {
            guard let album else { return }
            let colors = await library.artwork.albumDetailPalette(album)
            guard !Task.isCancelled else { return }
            automatic = colors
            if !colorsReady {
                backgroundInput = draft.backgroundHex ?? colors.background.hex
                textInput = draft.textHex ?? colors.foreground.hex
                accentInput = draft.accentHex ?? colors.accent.hex
                colorsReady = true
            }
        }
        .task(id: previewKey) {
            guard let album else { return }
            preparing = true
            let style = await library.artwork.albumPanelStyle(album, appearance: settings)
            guard !Task.isCancelled else { return }
            // Update text and scene together so changing a picker never creates
            // an unreadable intermediate frame with old imagery and new ink.
            preview = style; preparing = false
        }
        .onDisappear { NSColorPanel.shared.close() }
    }

    private func colorRow(_ label: String, input: Binding<String>,
                          fallback: AlbumDetailPalette.RGB) -> some View {
        HStack(spacing: 8) {
            ColorPicker(label, selection: Binding(get: {
                (AlbumDetailPalette.RGB(hex: input.wrappedValue) ?? fallback).color
            }, set: { color in
                input.wrappedValue = NSColor(color).hexString
            }), supportsOpacity: false)
            TextField("Hex", text: input)
                .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                .frame(width: 80)
                .accessibilityLabel("\(label) hex color")
        }
    }
}

private struct AlbumAppearancePreview: View {
    let album: Album
    let tracks: [Track]
    let style: AlbumPanelStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(album.title).font(.custom("Helvetica Neue", size: 22).weight(.bold)).lineLimit(2)
                .foregroundStyle(style.colors.foreground.color)
            Text(album.artist).font(.custom("Helvetica Neue", size: 14)).foregroundStyle(style.colors.accent.color)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 13) {
                    Label("Play Album", systemImage: "play.fill").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(style.colors.accent.color)
                    ForEach(tracks) { track in
                        HStack(spacing: 8) {
                            Text(track.trackNumber.map(String.init) ?? "–").frame(width: 14)
                                .foregroundStyle(style.colors.secondary.color)
                            Text(track.title).lineLimit(1).foregroundStyle(style.colors.foreground.color)
                            Spacer(minLength: 0)
                            Text(formatTime(track.duration)).foregroundStyle(style.colors.secondary.color)
                        }
                        .font(.custom("Helvetica Neue", size: 11))
                    }
                    Text("\(album.trackIDs.count) tracks").font(.system(size: 10)).foregroundStyle(style.colors.secondary.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ArtworkView(album: album, pointSize: 168, cornerRadius: 0).frame(width: 168, height: 168)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 520, height: 360, alignment: .topLeading)
        .background(AlbumSceneBackground(style: style))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Album track panel preview")
    }
}
