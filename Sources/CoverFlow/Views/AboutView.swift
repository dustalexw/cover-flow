import SwiftUI
import AppKit

struct AboutView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismissWindow) private var dismissWindow

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 7) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 112, height: 112)
                    .shadow(color: Palette.accent(scheme).opacity(0.25), radius: 18, y: 6)
                    .accessibilityLabel("Cover Flow app icon")
                Text("Cover Flow")
                    .font(.system(size: 34, weight: .bold, design: .serif))
                    .foregroundStyle(Palette.accent(scheme))
                Text("Browse your music by its covers.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                Text("Version \(version) · Build \(build)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Palette.raised(scheme), in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.hairline(scheme)))
                    .padding(.top, 3)
            }

            VStack(alignment: .leading, spacing: 15) {
                feature("Browse by cover", "Cover Flow, Grid, and Album View — from a mini-player to immersive artwork.", icon: "rectangle.stack")
                feature("Listen without gaps", "Continuous playback, an editable queue, and optional Last.fm scrobbling.", icon: "waveform")
                feature("Keep your music yours", "Play files where they are. Your original audio stays untouched.", icon: "music.note.house")
            }
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.raised(scheme), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline(scheme)))

            HStack(spacing: 10) {
                Link("Releases", destination: URL(string: "https://github.com/dustalexw/cover-flow/releases/latest")!)
                Link("Source on GitHub", destination: URL(string: "https://github.com/dustalexw/cover-flow")!)
                Link("Report an issue", destination: URL(string: "https://github.com/dustalexw/cover-flow/issues")!)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            VStack(spacing: 5) {
                Text("Made by dustalexw")
                    .font(.system(size: 12, weight: .medium))
                Text("Powered by SwiftUI · AppKit · AVFoundation")
                Link("MilkDrop visuals by projectM · LGPL 2.1+", destination: URL(string: "https://github.com/projectM-visualizer/projectm")!)
                Text("macOS 14 or later · Apple silicon + Intel")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Button("Close") { dismissWindow(id: "about") }
                .keyboardShortcut(.cancelAction)
                .controlSize(.regular)
        }
        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 20)
        .frame(width: 520)
        .background(LinearGradient(colors: scheme == .dark
                                   ? [Color(red: 0.086, green: 0.149, blue: 0.29), Palette.base(scheme)]
                                   : [Color(red: 0.985, green: 0.972, blue: 0.94), Palette.base(scheme)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .tint(Palette.accent(scheme))
        .preferredColorScheme(state.colorScheme)
    }

    private func feature(_ title: String, _ detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17)).foregroundStyle(Palette.accent(scheme))
                .frame(width: 23).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
