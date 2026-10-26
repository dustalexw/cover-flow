import PhotosUI
import SwiftUI

struct MobileAlbumView: View {
  let albumID: UUID
  @EnvironmentObject private var library: LibraryStore
  @EnvironmentObject private var player: PlayerEngine
  @Environment(\.dismiss) private var dismiss
  @State private var editing = false
  @State private var downloadArtwork = false
  @State private var appearance = false
  @State private var remove = false
  @State private var photo: PhotosPickerItem?
  @State private var trackEdit: Track?
  @State private var trackToRemove: Track?
  @State private var confirmingTrackRemoval = false
  var album: Album? { library.album(albumID) }
  var body: some View {
    NavigationStack {
      if let album {
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            ViewThatFits(in: .horizontal) {
              HStack(alignment: .center, spacing: 32) {
                MobileArtwork(album: album, pixels: 1400).frame(width: 300)
                header(album).frame(minWidth: 200)
              }
              VStack(alignment: .leading, spacing: 24) {
                MobileArtwork(album: album, pixels: 1000).frame(maxWidth: 340).frame(
                  maxWidth: .infinity)
                header(album)
              }
            }
            VStack(spacing: 0) {
              ForEach(library.tracks(of: album)) { track in
                Button {
                  player.play(albumID: album.id, startAt: track.id)
                } label: {
                  MobileTrackRow(
                    track: track, playing: player.currentTrackID == track.id && player.isPlaying)
                }
                .buttonStyle(.plain).contextMenu {
                  Button("Play", systemImage: "play.fill") {
                    player.play(albumID: album.id, startAt: track.id)
                  }
                  Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    player.playNext([track.id])
                  }
                  Button("Add to Queue", systemImage: "text.append") {
                    player.addToQueue([track.id])
                  }
                  Button("Edit Track", systemImage: "pencil") { trackEdit = track }
                  ShareLink(item: track.fileURL) {
                    Label("Share Audio", systemImage: "square.and.arrow.up")
                  }
                  Divider()
                  Button("Remove from Collection", systemImage: "trash", role: .destructive) {
                    trackToRemove = track
                    confirmingTrackRemoval = true
                  }.disabled(library.importing)
                }
                Divider().opacity(0.4)
              }
            }.padding(.horizontal, 14).background(
              .regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            Text(
              "\(album.trackIDs.count) tracks · \(formatLongDuration(library.totalDuration(album)))"
            ).font(.footnote).foregroundStyle(.secondary)
          }.padding(28)
        }.background { MobileAlbumScene(album: album) }
          .navigationTitle(album.title).navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
              Menu {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                  player.playNext(album.trackIDs)
                }
                Button("Add to Queue", systemImage: "text.append") {
                  player.addToQueue(album.trackIDs)
                }
                Button("Edit Album", systemImage: "pencil") { editing = true }
                Button("Colors & Scene", systemImage: "paintpalette") { appearance = true }
                Button("Find Artwork Online…", systemImage: "photo.badge.magnifyingglass") { downloadArtwork = true }
                PhotosPicker(selection: $photo, matching: .images) {
                  Label("Replace Artwork", systemImage: "photo")
                }
                if album.hasArtwork {
                  Button("Remove Artwork", systemImage: "photo.badge.minus") {
                    library.removeArtwork(album.id)
                  }
                }
                Divider()
                Button("Remove Album", systemImage: "trash", role: .destructive) { remove = true }
              } label: {
                Image(systemName: "ellipsis.circle").frame(width: 32, height: 32)
              }.accessibilityLabel("Album actions")
            }
          }
          .sheet(isPresented: $downloadArtwork) {
            ArtworkDownloadView(album: album, saveDescription: "The cover will be saved to this iPad’s collection.") { data in
              guard library.album(album.id) != nil else { throw MusicLookupError.itemRemoved }
              try library.setArtwork(album.id, data: data)
            }
          }
          .sheet(isPresented: $editing) { MobileAlbumEditor(album: album) }
          .sheet(isPresented: $appearance) { MobileAppearanceEditor(album: album) }
          .sheet(item: $trackEdit) { track in MobileTrackEditor(track: track) }
          .confirmationDialog(
            "Remove this album and its imported audio from this iPad?", isPresented: $remove,
            titleVisibility: .visible
          ) {
            Button("Remove Album", role: .destructive) {
              library.removeAlbums([album.id])
              dismiss()
            }
          }
          .onChange(of: photo) { _, item in
            Task {
              do {
                if let data = try await item?.loadTransferable(type: Data.self) {
                  try library.setArtwork(album.id, data: data)
                }
              } catch { library.notice = error.localizedDescription }
            }
          }
      } else {
        ContentUnavailableView("Album unavailable", systemImage: "music.note")
      }
    }
    .alert("Remove Track from Collection?", isPresented: $confirmingTrackRemoval, presenting: trackToRemove) { track in
      Button("Remove Track", role: .destructive) {
        library.removeTracks([track.id])
        if library.album(albumID) == nil { dismiss() }
      }
      Button("Cancel", role: .cancel) { }
    } message: { track in
      Text("“\(track.title)” and its imported audio will be removed from this iPad and the playback queue. The original file in Files or iCloud will stay untouched.")
    }
    .preferredColorScheme(
      album?.panelAppearance.backgroundHex.map {
        Color(hex: $0).relativeLuminance < 0.179 ? .dark : .light
      })
  }
  private func header(_ album: Album) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(album.title).font(.system(.largeTitle, design: .serif).weight(.semibold)).fixedSize(
        horizontal: false, vertical: true)
      Text(album.artist).font(.title3).foregroundStyle(.secondary)
      Text([album.year.map(String.init), album.genre].compactMap { $0 }.joined(separator: " · "))
        .font(.subheadline).foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Button {
          player.play(albumID: album.id, shuffled: false)
        } label: {
          Label("Play", systemImage: "play.fill").frame(minWidth: 72)
        }.buttonStyle(.borderedProminent)
        Button {
          player.play(albumID: album.id, shuffled: true)
        } label: {
          Label("Shuffle", systemImage: "shuffle")
        }.buttonStyle(.bordered)
      }.controlSize(.large)
    }
  }
}
struct MobileTrackRow: View {
  let track: Track
  var playing = false
  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      Group {
        if playing {
          Image(systemName: "waveform").foregroundStyle(MobilePalette.brass)
        } else {
          Text(track.trackNumber.map(String.init) ?? "—").foregroundStyle(.secondary)
        }
      }.font(.caption.monospacedDigit()).frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        Text(track.title).font(.body).foregroundStyle(.primary).fixedSize(
          horizontal: false, vertical: true)
        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 10)
      Text(formatTime(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }.padding(.vertical, 14).contentShape(Rectangle()).accessibilityElement(children: .combine)
  }
}
struct MobileAlbumScene: View {
  let album: Album
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    GeometryReader { size in
      ZStack {
        Color(
          hex: album.panelAppearance.backgroundHex,
          fallback: scheme == .dark ? MobilePalette.navy : MobilePalette.cream)
        if album.panelAppearance.sceneEnabled {
          MobileArtwork(album: album, pixels: 600).frame(
            width: max(size.size.width, size.size.height) * 1.4
          ).rotationEffect(.degrees(Double(album.panelAppearance.sceneVariation % 12) * 30)).blur(
            radius: 60
          ).opacity(album.panelAppearance.strength * 0.35)
          LinearGradient(
            colors: [.clear, Color(uiColor: .systemBackground).opacity(0.65)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        }
      }.frame(width: size.size.width, height: size.size.height).clipped()
    }.ignoresSafeArea().accessibilityHidden(true)
  }
}
struct MobileAlbumEditor: View {
  let album: Album
  @EnvironmentObject private var library: LibraryStore
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var artist = ""
  @State private var year = ""
  @State private var genre = ""
  var body: some View {
    NavigationStack {
      Form {
        Section("Album") {
          TextField("Title", text: $title, axis: .vertical)
          TextField("Album artist", text: $artist)
          TextField("Year", text: $year).keyboardType(.numberPad)
          TextField("Genre", text: $genre)
        }
        Section {
          Text(
            "Edits update this iPad’s collection. Your imported audio files retain their original tags."
          ).font(.footnote).foregroundStyle(.secondary)
        }
      }.navigationTitle("Edit Album").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            library.updateAlbum(album.id, title: title, artist: artist, year: year, genre: genre)
            dismiss()
          }
        }
      }.onAppear {
        title = album.title
        artist = album.artist
        year = album.year.map(String.init) ?? ""
        genre = album.genre ?? ""
      }
    }
  }
}
struct MobileTrackEditor: View {
  let track: Track
  @EnvironmentObject private var library: LibraryStore
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var artist = ""
  @State private var number = ""
  var body: some View {
    NavigationStack {
      Form {
        TextField("Track title", text: $title, axis: .vertical)
        TextField("Artist", text: $artist)
        TextField("Track number", text: $number).keyboardType(.numberPad)
      }.navigationTitle("Edit Track").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            library.updateTrack(track.id, title: title, artist: artist, number: Int(number))
            dismiss()
          }
        }
      }.onAppear {
        title = track.title
        artist = track.artist
        number = track.trackNumber.map(String.init) ?? ""
      }
    }
  }
}
struct MobileAppearanceEditor: View {
  let album: Album
  @EnvironmentObject private var library: LibraryStore
  @Environment(\.dismiss) private var dismiss
  @State private var settings = AlbumAppearance()
  @State private var color = MobilePalette.navy
  @State private var customColor = false
  var preview: Album {
    var value = album
    var appearance = settings
    appearance.backgroundHex = customColor ? color.hexRGB : nil
    value.appearance = appearance
    return value
  }
  var body: some View {
    NavigationStack {
      Form {
        Section {
          ZStack {
            MobileAlbumScene(album: preview)
            HStack {
              MobileArtwork(album: album).frame(width: 110)
              Text(album.title).font(.title3).fixedSize(horizontal: false, vertical: true)
            }.padding()
          }.frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 14)).environment(
            \.colorScheme, customColor && color.relativeLuminance < 0.179 ? .dark : .light)
        }
        Section("Scene") {
          Toggle("Artwork scene", isOn: $settings.sceneEnabled)
          Slider(value: $settings.sceneStrength, in: 0...1) { Text("Scene strength") }
          Button("New Variation") { settings.sceneVariation += 1 }
        }
        Section("Background") {
          Toggle("Custom background", isOn: $customColor)
          if customColor { ColorPicker("Color", selection: $color, supportsOpacity: false) }
        }
        Section {
          Button("Reset to Cover") {
            settings = AlbumAppearance()
            customColor = false
          }
        }
      }.navigationTitle("Colors & Scene").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            settings.backgroundHex = customColor ? color.hexRGB : nil
            library.updateAppearance(album.id, appearance: settings)
            dismiss()
          }
        }
      }.onAppear {
        settings = album.panelAppearance
        customColor = settings.backgroundHex != nil
        color = Color(hex: settings.backgroundHex, fallback: MobilePalette.navy)
      }
    }
  }
}
extension Color {
  var relativeLuminance: Double {
    let color = UIColor(self)
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    func linear(_ value: CGFloat) -> Double {
      let value = Double(value)
      return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
  }
  var hexRGB: String {
    let color = UIColor(self)
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    return String(
      format: "#%02X%02X%02X", Int((r.clamped(0, 1) * 255).rounded()),
      Int((g.clamped(0, 1) * 255).rounded()), Int((b.clamped(0, 1) * 255).rounded()))
  }
}
