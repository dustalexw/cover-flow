import SwiftUI
import AppKit

struct SettingsView: View {
    private var mediaExplanation: String {
        guard media.keepOrganized else {
            return "Off: Cover Flow plays files where they are and never copies or moves them."
        }
        let how = media.mode == .copy
            ? "A copy of each imported file goes into the media folder; your originals stay where they are."
            : "Imported files are moved into the media folder. Files that can’t be moved (for example on a locked or read-only drive) are copied instead."
        return how + " Files are arranged as Artist › Album › “01 Title”. Lyric files (.lrc) beside a track come along with it."
    }

    private var organizeTitle: String {
        organizeCount == 0 ? "Everything is already in your media folder"
            : "\(media.mode == .copy ? "Copy" : "Move") \(organizeCount == 1 ? "1 file" : "\(organizeCount) files") into your media folder?"
    }

    private var organizeMessage: String {
        guard organizeCount > 0 else { return "There’s nothing to organize." }
        let what = media.mode == .copy
            ? "Copies go into \(media.displayPath); your original files stay where they are."
            : "The files are moved into \(media.displayPath) and removed from their current folders."
        return what + " Karaoke versions you’ve prepared for these tracks will need preparing again."
    }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var albumView: AlbumViewController
    @EnvironmentObject private var media: MediaLibrarySettings
    @State private var confirmClear = false
    @State private var confirmOrganize = false
    @State private var organizeCount = 0

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $state.theme) {
                    ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Dark lets covers stand out most. The background takes a quiet tint from the album you’re browsing.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Album View") {
                Toggle("Keep Album View above other windows", isOn: $albumView.keepOnTop)
                Toggle("Artwork focus: hide controls when idle", isOn: $albumView.focusMode)
                Text("Size and position are remembered between launches. Immersive always hides controls after a few seconds; move the pointer or press any key to bring them back.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Media Folder") {
                Toggle("Keep media organized", isOn: $media.keepOrganized)
                Picker("When importing", selection: $media.mode) {
                    ForEach(MediaImportMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!media.keepOrganized)
                LabeledContent("Location") {
                    HStack(spacing: 8) {
                        Text(media.displayPath)
                            .lineLimit(1).truncationMode(.middle)
                            .help(media.folder.path)
                        Button("Change…") { media.chooseFolder() }
                    }
                }
                .disabled(!media.keepOrganized)
                Text(mediaExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Organize Existing Music…") {
                        organizeCount = library.tracksOutsideMediaFolder().count
                        confirmOrganize = true
                    }
                    .disabled(!media.keepOrganized || library.importProgress != nil || library.albums.isEmpty)
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: media.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([media.folder])
                    }
                    .disabled(!media.keepOrganized)
                    if media.folder.standardizedFileURL != MediaLibrarySettings.defaultFolder.standardizedFileURL {
                        Button("Use Default") { media.resetFolder() }
                            .disabled(!media.keepOrganized)
                    }
                }
            }

            LastFmSettings()

            Section("Your Library & Saved Data") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(media.keepOrganized
                         ? "New imports go into your media folder (see Media Folder above). If you move or rename a file there yourself, it will show as missing."
                         : "Cover Flow plays your audio files where they are — it never copies or moves them. If you move or rename a file, it will show as missing.")
                    Text("Library data saved on this Mac:")
                        .padding(.top, 4)
                    Text("• Collection, album edits and play history — Library.json")
                    Text("• Queue, playback position, shuffle, repeat and volume — Playback.json")
                    Text("• Artwork (originals, for sharp large covers) — Artwork folder")
                    Text("• Window layout and preferences — system preferences")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Show Data Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.library.deletingLastPathComponent()])
                }
            }

            Section("Demo Collection") {
                Text("Five clearly labelled demo albums with original synthesized music and generated covers, made on this Mac. Remove them any time; your own music is unaffected.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(library.hasDemoContent ? "Rebuild Demo Collection" : "Add Demo Collection") { library.addDemoCollection() }
                        .disabled(library.isGeneratingDemo)
                    if library.hasDemoContent {
                        Button("Remove Demo Collection") { library.removeDemoCollection() }
                    }
                }
            }

            Section("Reset") {
                Button("Remove Everything from Collection…", role: .destructive) { confirmClear = true }
                    .disabled(library.albums.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 700)
        .confirmationDialog(organizeTitle, isPresented: $confirmOrganize) {
            if organizeCount > 0 {
                Button(media.mode == .copy ? "Copy Files" : "Move Files") { library.organizeExistingLibrary() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(organizeMessage)
        }
        .confirmationDialog("Remove every album from Cover Flow?", isPresented: $confirmClear) {
            Button("Remove All", role: .destructive) { library.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your audio files stay on disk. You can import them again later.")
        }
        .preferredColorScheme(state.colorScheme)
    }
}
