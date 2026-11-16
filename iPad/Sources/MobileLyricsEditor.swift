import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The editor's own player, so the music can slow down while you sync (as in
/// Lyripass). Formats AVAudioPlayer can't open (Opus, APE and others decoded with
/// FFmpeg) play through Cover Flow's player instead, at normal speed.
@MainActor final class LyricsEditorAudio: ObservableObject {
  @Published private(set) var time: Double = 0
  @Published private(set) var duration: Double = 0
  @Published private(set) var playing = false
  @Published var rate: Float = 1 {
    didSet { local?.rate = rate }
  }
  private(set) var canChangeSpeed = false
  private var local: AVAudioPlayer?
  private weak var engine: PlayerEngine?
  private var track: Track?
  private var albumID: UUID?
  private var timer: AnyCancellable?

  func open(_ track: Track, albumID: UUID?, engine: PlayerEngine) {
    self.track = track
    self.albumID = albumID
    self.engine = engine
    engine.pause()
    if let player = try? AVAudioPlayer(contentsOf: track.fileURL) {
      player.enableRate = true
      player.prepareToPlay()
      local = player
      canChangeSpeed = true
      duration = player.duration
      time = 0
    } else {
      local = nil
      canChangeSpeed = false
      duration = track.duration
      time = engine.currentTrackID == track.id ? engine.currentTime : 0
    }
    timer = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in
      self?.tick()
    }
  }

  func close() {
    local?.stop()
    if local == nil, playing { engine?.pause() }
    timer = nil
    playing = false
  }

  private func tick() {
    if let local {
      time = local.currentTime
      if playing && !local.isPlaying { playing = false }
    } else if let engine, let track, engine.currentTrackID == track.id {
      time = engine.currentTime
      playing = engine.isPlaying
    }
  }

  func toggle() { playing ? pause() : play() }

  func play() {
    if let local {
      local.rate = rate
      local.play()
      playing = true
    } else if let engine, let track {
      if engine.currentTrackID != track.id, let albumID {
        engine.play(albumID: albumID, startAt: track.id)
        if time > 0 { engine.seek(to: time) }
      } else if !engine.isPlaying {
        engine.togglePlayPause()
      }
      playing = true
    }
  }

  func pause() {
    local?.pause()
    if local == nil, let engine, engine.isPlaying { engine.pause() }
    playing = false
  }

  func seek(to seconds: Double) {
    let target = max(0, min(seconds, max(0, duration - 0.05)))
    if let local {
      local.currentTime = target
    } else if let engine, let track, engine.currentTrackID == track.id {
      engine.seek(to: target)
    }
    time = target
  }

  /// Plays from a moment (a little before it, so the line's start can be heard).
  func play(from seconds: Double, lead: Double = 0.5) {
    seek(to: seconds - lead)
    play()
  }
}

/// Lyripass's lyrics editor: edit plain lyrics, sync lines to the music, and fine-tune
/// word timings, then save them for the track.
struct MobileLyricsEditor: View {
  let track: Track
  var onSaved: () -> Void = {}
  @EnvironmentObject private var library: LibraryStore
  @EnvironmentObject private var player: PlayerEngine
  @EnvironmentObject private var lyrics: LyricsStore
  @Environment(\.dismiss) private var dismiss
  @StateObject private var audio = LyricsEditorAudio()
  @State private var draft = LyricsDraft()
  @State private var original = LyricsDraft()
  @State private var tab: Tab = .synced
  @State private var selected: Int?
  @State private var wordLine: Int?
  @State private var loaded = false
  @State private var confirmUnsynced = false
  @State private var confirmDiscard = false
  @State private var importingLRC = false
  @State private var message: String?

  enum Tab: String, CaseIterable, Identifiable {
    case plain = "Plain", synced = "Synced"
    var id: String { rawValue }
  }

  private var dirty: Bool { draft != original }
  private var directory: URL { AppPaths.root.appendingPathComponent("Lyrics", isDirectory: true) }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        playerBar
        Divider()
        if draft.instrumental {
          ContentUnavailableView {
            Label("Marked as instrumental", systemImage: "pianokeys")
          } description: {
            Text("The track is saved as having no lyrics.")
          } actions: {
            Button("Unmark as Instrumental") { draft.instrumental = false }
          }
        } else if tab == .plain {
          plainEditor
        } else {
          syncedEditor
        }
      }
      .navigationTitle(track.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dirty ? (confirmDiscard = true) : close() }
        }
        ToolbarItem(placement: .principal) {
          Picker("Lyrics", selection: $tab) {
            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
          }.pickerStyle(.segmented).frame(width: 180).disabled(draft.instrumental)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { draft.unsyncedCount > 0 && draft.isSynced ? (confirmUnsynced = true) : save() }
            .disabled(!dirty)
        }
        ToolbarItem(placement: .topBarTrailing) { moreMenu }
      }
      .confirmationDialog(
        "\(draft.unsyncedCount) line\(draft.unsyncedCount == 1 ? " isn’t" : "s aren’t") synced yet",
        isPresented: $confirmUnsynced, titleVisibility: .visible
      ) {
        Button("Save Synced Lines Only") { save() }
        Button("Keep Editing", role: .cancel) {}
      } message: {
        Text("Lines without a time are left out of the synced lyrics.")
      }
      .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
        Button("Discard Changes", role: .destructive) { close() }
      }
      .fileImporter(isPresented: $importingLRC, allowedContentTypes: lyricTypes) { result in
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count < 2 * 1024 * 1024,
          let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
        else {
          message = "That file couldn’t be read."
          return
        }
        replace(with: text)
      }
      .sheet(
        isPresented: Binding(get: { wordLine != nil }, set: { if !$0 { wordLine = nil } })
      ) {
        if let index = wordLine, draft.lines.indices.contains(index) {
          MobileWordTimingEditor(draft: $draft, index: index, audio: audio)
            .presentationDetents([.medium, .large])
        }
      }
    }
    .interactiveDismissDisabled(dirty)
    .task {
      guard !loaded else { return }
      loaded = true
      let item = track
      let folder = directory
      let text = await Task.detached { MobileLyricsLibrary.text(for: item, directory: folder) }.value
      let parsed = text.map(LyricsDraft.parse) ?? LyricsDraft()
      draft = parsed
      original = parsed
      tab = parsed.isSynced || parsed.plainText.isEmpty ? .synced : .plain
      if tab == .synced && draft.lines.isEmpty && !draft.plain.isEmpty { draft.linesFromPlain() }
      audio.open(track, albumID: library.albumID(forTrack: track.id), engine: player)
    }
    .onDisappear { audio.close() }
  }

  private var lyricTypes: [UTType] {
    ["lrc", "txt", "lyric", "lyrics"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
  }

  // MARK: Player

  private var playerBar: some View {
    VStack(spacing: 6) {
      HStack(spacing: 14) {
        Button {
          audio.seek(to: audio.time - 5)
        } label: {
          Image(systemName: "gobackward.5").font(.title3)
        }.accessibilityLabel("Back 5 seconds")
        Button {
          audio.toggle()
        } label: {
          Image(systemName: audio.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 38))
        }.accessibilityLabel(audio.playing ? "Pause" : "Play")
        Button {
          audio.seek(to: audio.time + 5)
        } label: {
          Image(systemName: "goforward.5").font(.title3)
        }.accessibilityLabel("Forward 5 seconds")
        Text("\(LyricsDraft.timestamp(audio.time)) / \(formatTime(audio.duration))")
          .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        if audio.canChangeSpeed {
          Menu {
            Picker("Speed", selection: $audio.rate) {
              ForEach([0.5, 0.6, 0.75, 0.9, 1.0] as [Float], id: \.self) { value in
                Text(value == 1 ? "Normal speed" : "\(Int((value * 100).rounded()))%").tag(value)
              }
            }
          } label: {
            Label(audio.rate == 1 ? "1×" : "\(Int((audio.rate * 100).rounded()))%", systemImage: "tortoise")
              .font(.callout.monospacedDigit())
          }.accessibilityLabel("Playback speed")
        }
      }
      Slider(
        value: Binding(get: { audio.time }, set: { audio.seek(to: $0) }),
        in: 0...max(1, audio.duration)
      ).accessibilityLabel("Position")
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
    .buttonStyle(.plain)
  }

  // MARK: Plain

  private var plainEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextEditor(text: $draft.plain)
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
      problemList(draft.lines.isEmpty ? draft.problems() : [])
      HStack {
        Button("Sync These Lines") {
          draft.linesFromPlain()
          tab = .synced
          selected = draft.lines.firstIndex { $0.start == nil }
        }.buttonStyle(.borderedProminent).disabled(draft.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Spacer()
        Text("One line per lyric line. Section labels like [Chorus] aren’t synced.")
          .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
      }
    }
    .padding(16)
  }

  // MARK: Synced

  private var activeLine: Int? { draft.activeLine(at: audio.time) }

  private var syncedEditor: some View {
    VStack(spacing: 0) {
      if draft.lines.isEmpty {
        ContentUnavailableView {
          Label("No lines to sync", systemImage: "text.badge.plus")
        } description: {
          Text("Write or paste the lyrics in Plain, then sync them here line by line while the song plays.")
        } actions: {
          Button("Write Plain Lyrics") { tab = .plain }
          Button("Add a Line") { draft.insertLine(after: nil); selected = 0 }
        }
      } else {
        ScrollViewReader { reader in
          List {
            ForEach(Array(draft.lines.enumerated()), id: \.element.id) { index, line in
              lineRow(index, line).id(line.id)
                .listRowBackground(rowBackground(index))
            }
            problemList(draft.problems())
          }
          .listStyle(.plain)
          .onChange(of: selected) { _, value in
            if let value, draft.lines.indices.contains(value) {
              withAnimation { reader.scrollTo(draft.lines[value].id, anchor: .center) }
            }
          }
        }
        syncBar
      }
    }
  }

  private func rowBackground(_ index: Int) -> Color {
    index == selected ? Color.accentColor.opacity(0.16) : index == activeLine ? Color.primary.opacity(0.06) : Color.clear
  }

  private func lineRow(_ index: Int, _ line: LyricsDraftLine) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Button {
        if let start = line.start { audio.play(from: start) }
        selected = index
      } label: {
        Text(line.start.map(LyricsDraft.timestamp) ?? "--:--.--")
          .font(.callout.monospacedDigit().weight(.medium))
          .foregroundStyle(line.start == nil ? Color.secondary : Color.accentColor)
          .frame(width: 78, alignment: .leading)
      }.buttonStyle(.plain)
        .accessibilityLabel(line.start.map { "Starts at \(LyricsDraft.timestamp($0)). Play from here" } ?? "Not synced")
      TextField(
        "Lyric line",
        text: Binding(get: { draft.lines.indices.contains(index) ? draft.lines[index].text : "" },
                      set: { draft.setText(index, $0) }),
        axis: .vertical
      )
      .font(index == activeLine ? .body.weight(.semibold) : .body)
      if line.hasWordTimings {
        Image(systemName: "textformat.abc.dottedunderline").foregroundStyle(.secondary)
          .accessibilityLabel("Word timings")
      }
      Menu {
        Button("Sync to Now", systemImage: "metronome") { stamp(index) }
        Button("Play from Here", systemImage: "play") { if let start = line.start { audio.play(from: start) } }
          .disabled(line.start == nil)
        Button("Earlier by 0.1 s", systemImage: "minus") { draft.nudge(index, by: -0.1) }.disabled(line.start == nil)
        Button("Later by 0.1 s", systemImage: "plus") { draft.nudge(index, by: 0.1) }.disabled(line.start == nil)
        Button("Word Timings…", systemImage: "textformat.abc.dottedunderline") { wordLine = index }
          .disabled(line.start == nil || line.text.isEmpty)
        Button("Clear Time", systemImage: "clock.badge.xmark") { draft.clearTiming(index) }.disabled(line.start == nil)
        Divider()
        Button("Insert Line Below", systemImage: "text.insert") { draft.insertLine(after: index); selected = index + 1 }
        Button("Delete Line", systemImage: "trash", role: .destructive) {
          draft.deleteLine(index)
          if let s = selected, s >= draft.lines.count { selected = draft.lines.isEmpty ? nil : draft.lines.count - 1 }
        }
      } label: {
        Image(systemName: "ellipsis.circle").font(.title3).frame(width: 36, height: 36)
      }.accessibilityLabel("Line actions")
    }
    .contentShape(Rectangle())
    .simultaneousGesture(TapGesture().onEnded { selected = index })
  }

  /// Tap-along syncing: “Sync” times the selected line to what's playing now and
  /// moves to the next line.
  private var syncBar: some View {
    let target = selected ?? draft.lines.firstIndex { $0.start == nil } ?? 0
    return VStack(spacing: 8) {
      if draft.lines.indices.contains(target) {
        Text(draft.lines[target].text.isEmpty ? "♪" : draft.lines[target].text)
          .font(.headline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 10) {
        Button {
          draft.nudge(target, by: -0.1)
        } label: { Label("−0.1 s", systemImage: "minus") }
          .disabled(!draft.lines.indices.contains(target) || draft.lines[target].start == nil)
        Button {
          draft.nudge(target, by: 0.1)
        } label: { Label("+0.1 s", systemImage: "plus") }
          .disabled(!draft.lines.indices.contains(target) || draft.lines[target].start == nil)
        Button {
          if let start = draft.lines[safe: target]?.start { audio.play(from: start) }
        } label: { Label("Replay", systemImage: "arrow.counterclockwise") }
          .disabled(draft.lines[safe: target]?.start == nil)
        Spacer()
        Button {
          stamp(target)
          if !audio.playing { audio.play() }
        } label: {
          Label("Sync", systemImage: "metronome.fill").font(.headline).frame(minWidth: 96, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!draft.lines.indices.contains(target))
      }
      .buttonStyle(.bordered).labelStyle(.titleAndIcon).font(.callout)
    }
    .padding(14)
    .background(.bar)
  }

  private func stamp(_ index: Int) {
    guard draft.lines.indices.contains(index) else { return }
    draft.stamp(index, at: audio.time)
    selected = index + 1 < draft.lines.count ? index + 1 : index
  }

  @ViewBuilder private func problemList(_ problems: [LyricsProblem]) -> some View {
    if !problems.isEmpty {
      Section {
        ForEach(problems.prefix(12)) { problem in
          Label(problem.message, systemImage: problem.severity == .error ? "exclamationmark.octagon" : "exclamationmark.triangle")
            .font(.caption).foregroundStyle(problem.severity == .error ? Color.red : Color.orange)
            .onTapGesture { if let line = problem.line, tab == .synced { selected = line - 1 } }
        }
        if problems.count > 12 { Text("And \(problems.count - 12) more").font(.caption).foregroundStyle(.secondary) }
      }
    }
  }

  // MARK: More

  private var moreMenu: some View {
    Menu {
      Button("Import Lines from Plain", systemImage: "text.badge.plus") {
        draft.linesFromPlain()
        tab = .synced
      }.disabled(draft.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Button("Paste LRC", systemImage: "doc.on.clipboard") {
        if let text = UIPasteboard.general.string { replace(with: text) }
      }
      Button("Open LRC or Text File…", systemImage: "doc") { importingLRC = true }
      Divider()
      Menu("Shift All Lines", systemImage: "arrow.left.and.right") {
        ForEach([-1.0, -0.5, -0.1, 0.1, 0.5, 1.0], id: \.self) { delta in
          Button(String(format: "%+.1f s", delta)) { draft.shiftAll(by: delta) }
        }
      }.disabled(!draft.isSynced)
      Button("Sort Lines by Time", systemImage: "arrow.up.arrow.down") { draft.sortByTime() }
        .disabled(!draft.isSynced)
      Button("Spread Words in Every Line", systemImage: "textformat.abc.dottedunderline") {
        for i in draft.lines.indices where draft.lines[i].start != nil && !draft.lines[i].hasWordTimings {
          draft.spreadWords(i)
        }
      }.disabled(!draft.isSynced)
      Button("Remove Word Timings", systemImage: "textformat.abc") {
        for i in draft.lines.indices { draft.clearWords(i) }
      }.disabled(!draft.lines.contains { $0.hasWordTimings })
      Divider()
      Button(draft.instrumental ? "Unmark as Instrumental" : "Mark as Instrumental", systemImage: "pianokeys") {
        draft.instrumental.toggle()
      }
      ShareLink(
        item: draft.lrc(),
        preview: SharePreview(MobileLyricsLibrary.fileName(for: track, ext: "lrc"))
      ) {
        Label("Share as Text", systemImage: "square.and.arrow.up")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }.accessibilityLabel("More lyrics actions")
  }

  private func replace(with text: String) {
    let parsed = LyricsDraft.parse(text)
    guard !parsed.isEmpty else {
      message = "There were no lyrics to use."
      return
    }
    draft = parsed
    tab = parsed.isSynced ? .synced : .plain
    selected = nil
  }

  private func save() {
    let text = draft.lrc()
    let id = track.id
    let directory = directory
    Task {
      do {
        if draft.isEmpty {
          try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".lrc"))
        } else {
          _ = try await Task.detached(priority: .userInitiated) {
            try LyricsStore.importText(text, trackID: id, directory: directory)
          }.value
        }
        if lyrics.trackID == id { await lyrics.load(track: track) }
        original = draft
        onSaved()
        close()
      } catch {
        library.notice = error.localizedDescription
      }
    }
  }

  private func close() {
    audio.close()
    dismiss()
  }
}

/// Times a line word by word: tap “Next Word” in time with the singing, or spread the
/// words evenly and fine-tune them.
struct MobileWordTimingEditor: View {
  @Binding var draft: LyricsDraft
  let index: Int
  @ObservedObject var audio: LyricsEditorAudio
  @Environment(\.dismiss) private var dismiss
  @State private var next = 0

  private var line: LyricsDraftLine { draft.lines[index] }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        let active = draft.activeWord(line: index, at: audio.time)
        ScrollView {
          FlowWords(words: line.words, active: draft.activeLine(at: audio.time) == index ? active : nil, next: next) { w in
            next = w
          }
        }.frame(maxHeight: 220)
        if line.words.indices.contains(next) {
          HStack {
            Text("“\(line.words[next].text.trimmingCharacters(in: .whitespaces))”").font(.headline)
            Text(line.words[next].start.map(LyricsDraft.timestamp) ?? "not timed").font(.callout.monospacedDigit())
              .foregroundStyle(.secondary)
            Spacer()
            Button { nudge(-0.05) } label: { Image(systemName: "minus") }.disabled(line.words[next].start == nil)
              .accessibilityLabel("Earlier")
            Button { nudge(0.05) } label: { Image(systemName: "plus") }.disabled(line.words[next].start == nil)
              .accessibilityLabel("Later")
          }.buttonStyle(.bordered)
        }
        HStack(spacing: 10) {
          Button("Spread Evenly") {
            draft.spreadWords(index)
            next = 0
          }
          Button("Clear") {
            draft.clearWords(index)
            draft.splitWords(index)
            next = 0
          }
          Button {
            if let start = line.start { audio.play(from: start, lead: 0.8) }
            next = 0
          } label: { Label("Play Line", systemImage: "play") }
          Spacer()
          Button {
            guard line.words.indices.contains(next) else { return }
            draft.stampWord(line: index, word: next, at: audio.time)
            next = min(next + 1, line.words.count - 1)
            if !audio.playing { audio.play() }
          } label: {
            Label("Next Word", systemImage: "hand.tap.fill").font(.headline).frame(minHeight: 32)
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.space, modifiers: [])
        }
        .buttonStyle(.bordered)
        Text("Play the line, then tap Next Word as each word starts. Tap a word to retime it from there. Slow the music down with the tortoise in the editor.")
          .font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .padding(18)
      .navigationTitle("Word Timings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
      .onAppear {
        if line.words.isEmpty { draft.splitWords(index) }
        next = line.words.firstIndex { $0.start == nil } ?? 0
      }
    }
  }

  private func nudge(_ delta: Double) {
    guard line.words.indices.contains(next), let start = line.words[next].start else { return }
    draft.stampWord(line: index, word: next, at: start + delta)
  }
}

/// A line's words as tappable chips that wrap.
private struct FlowWords: View {
  let words: [LyricsDraftWord]
  let active: Int?
  let next: Int
  let onTap: (Int) -> Void

  var body: some View {
    WrappingLayout(spacing: 6) {
      ForEach(Array(words.enumerated()), id: \.offset) { i, word in
        Button {
          onTap(i)
        } label: {
          VStack(spacing: 2) {
            Text(word.text.trimmingCharacters(in: .whitespaces)).font(.title3.weight(i == active ? .bold : .regular))
            Text(word.start.map(LyricsDraft.timestamp) ?? "—").font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, 10).padding(.vertical, 6)
          .background(
            i == next ? Color.accentColor.opacity(0.22) : i == active ? Color.primary.opacity(0.1) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 10)
          )
          .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(i == next ? Color.accentColor : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain)
      }
    }
  }
}

/// Lays children out left to right, wrapping onto new rows.
struct WrappingLayout: Layout {
  var spacing: CGFloat = 6
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 400
    var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
      x += size.width + spacing
      widest = max(widest, x - spacing)
      row = max(row, size.height)
    }
    return CGSize(width: min(width, widest), height: y + row)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      row = max(row, size.height)
    }
  }
}
