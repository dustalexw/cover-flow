import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var albumView: AlbumViewController
    @State private var confirmClear = false

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

            Section("Your Library & Saved Data") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cover Flow plays your audio files where they are — it never copies, moves or edits them. If you move or rename a file, it will show as missing.")
                    Text("Saved on this Mac only:")
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
        .frame(width: 520, height: 620)
        .confirmationDialog("Remove every album from Cover Flow?", isPresented: $confirmClear) {
            Button("Remove All", role: .destructive) { library.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your audio files stay on disk. You can import them again later.")
        }
        .preferredColorScheme(state.colorScheme)
    }
}
