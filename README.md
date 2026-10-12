<p align="center"><img src="docs/readme-header.png" alt="Cover Flow 1.2.0 — Only on macOS; browse your music by its covers" width="100%"></p>

<p align="center">
  <a href="https://github.com/dustalexw/cover-flow/releases/tag/v1.2.0"><img src="docs/badge-release.svg" alt="Release v1.2.0"></a>
  <a href="https://github.com/dustalexw/cover-flow/releases/download/v1.2.0/Cover-Flow-1.2.0-macOS.zip"><img src="docs/badge-download.svg" alt="Download the macOS app"></a>
  <a href="#download-the-macos-app"><img src="docs/badge-platform.svg" alt="Platform: macOS 14 or later, Apple silicon and Intel"></a>
</p>

# Cover Flow

A native macOS audio player built around browsing a record collection: a 3D Cover Flow,
a grid, and **Album View**, a player window that scales from a compact mini-player to an
almost full-screen cover.

Choose **Cover Flow → About Cover Flow…** for the app version, feature overview,
credits, and links to releases, source code, and issue reporting.

## Download the macOS app

Download **Cover-Flow-1.2.0-macOS.zip** from the
[1.2.0 release](https://github.com/dustalexw/cover-flow/releases/tag/v1.2.0), unzip it, and move
**Cover Flow.app** to Applications. The universal app runs on Apple silicon and Intel Macs
with macOS 14 or later. The app is
ad-hoc signed rather than notarized, so the first time, right-click it and choose **Open**.

## What’s new in 1.2.0

Each album’s track panel has its own **Colors & Scene** editor. Choose background,
text, and accent colors with native color pickers or hex values. A live preview
shows the result before you save; Cancel leaves the album unchanged.

Static, content-aware scenes extend the shapes, textures, and colors of the cover.
They are generated on your Mac, cached as still images, and kept quieter behind
track names. Contrast protection keeps custom text and accents readable. Choose
scene strength, regenerate a variation, turn the scene off, or **Reset to Cover**.
The settings apply only to that album’s track panel. New artwork refreshes its scene.

The app and MilkDrop remain universal for Apple silicon and Intel. The Dock icon
restores a closed collection window, including with Album View or MilkDrop open.

## Build & run

Double-click **build.command** in Finder (or run `./build.command` in Terminal). It compiles a
universal release build with the Swift toolchain from Xcode, assembles **Cover Flow.app** next to the
script, signs it for local use and launches it. Requires macOS 14 or later and Xcode (or the
Command Line Tools). You can drag `Cover Flow.app` into /Applications.
The first build downloads verified projectM 4.1.8 source and, if needed, a local
CMake tool. Later builds reuse them. No Homebrew installation is required.
Use `./build.command --no-launch` to assemble the app without launching it.
Both the app and projectM are built for `arm64` and `x86_64`; the build verifies
that both architectures are present before signing the package.

## MilkDrop visualizer

Click the waveform button in the top bar or press **⌘3** to open MilkDrop.
The resizable window uses projectM to render real MilkDrop presets from the
audio currently playing. Eight original presets are included. Use **← / →**
to switch presets, **Space** to pause or resume, and the full-screen button to
fill the display. **Escape** leaves full screen or closes the visualizer.
Turn **Auto** off to hold a preset; otherwise it changes every 25 seconds.

Choose **Add MilkDrop Presets…** from the preset menu to import `.milk` files.
Imported presets are stored in Application Support/CoverFlow/Visualizer/Presets.
Rendering stops when the window closes or is hidden, and opening or resizing it
does not restart music. The visualizer uses the player's audio directly.
See [third-party notices](Resources/ThirdPartyNotices.md) for licenses, included
engine source, and instructions for replacing the projectM library.

## Gapless playback

Cover Flow plays queued tracks as one continuous audio stream, preparing audio ahead
of each transition. Repeat One and Repeat All use the same gapless path. Tracks with different
sample rates or channel counts are converted to a shared output format, and decoding uses a
bounded buffer rather than loading entire songs into memory. Silence already present in a
recording is preserved.

Run the playback checks with `swift test`.

## Last.fm and album selection

In **Settings → Last.fm → Set Up Last.fm**, enter the API key and shared secret from your
[Last.fm API account](https://www.last.fm/api/account/create). Choose **Connect Last.fm**,
approve access in your browser, then click **Finish Connecting**. Credentials are saved in
macOS Keychain; Cover Flow never asks for your Last.fm password. You can pause scrobbling or
disconnect in Settings.

Tagged tracks send Now Playing and scrobble after half the song or four minutes of actual
listening, whichever comes first. Tracks must be longer than 30 seconds. Pauses and seeks do
not earn listening credit; demo tracks and tracks with incomplete metadata are skipped.
Eligible listens are cached locally during outages and retried for the same account.
Changing app credentials or disconnecting clears pending listens.

Click an album to open its tracks, **Shift-click** to select a range, and **Command-click** to toggle
individual albums. In Grid, drag across cards to select a group; hold Shift or Command while
dragging to add to the selection. In Cover Flow, Shift-drag or Shift-arrow selects a range.
The selection bar plays or queues albums together in their displayed order. **Command-A**
selects all visible albums and **Escape** clears the selection. Return also shows album tracks.

The album track panel takes its cues from early iTunes: Helvetica typography, compact song
columns, small playback buttons and a large cover on the right. Its full background and text
colors come from the artwork, with readable foregrounds for both light and dark covers.
Long albums scroll, multiple discs retain their headings, and albums without artwork use a
palette matching their generated placeholder.
Artwork colors and the cover thumbnail are prepared before the track panel opens and cached
by artwork version, so opening an album does not flash a temporary background color.
Click outside the album track panel or press **Escape** to close it. Outside clicks keep
an active editing or confirmation dialog open. **Space** pauses or resumes the current music
even while the track panel is open.

## Why this stack

SwiftUI + AVFoundation, packaged with Swift Package Manager: native 3D transforms and springs
for Cover Flow, AVFoundation for playback and tag/artwork reading, AppKit where SwiftUI is thin
(the Album View window, scroll-wheel capture, open panels, media keys).

## Layout

| Folder | Responsibility |
| --- | --- |
| `Model` | Track / Album values, sort and repeat modes, storage paths |
| `Library` | Import, metadata (AVFoundation + a small FLAC reader), album grouping, artwork cache, persistence, demo collection |
| `Playback` | `PlayerEngine` — queue, shuffle/repeat, seeking, volume, errors, Now Playing + media keys |
| `Scrobbling` | Last.fm authorization, Keychain credentials, listening progress and durable retry queue |
| `Views` | Cover Flow, grid, album sheet, editor, queue, player bar, settings |
| `AlbumView` | Album View window controller (presets, resize, position memory) and its content |

Playback, metadata, collection state and presentation are separate objects, so each can change
without touching the others. Every view observes the same `PlayerEngine`, which keeps state in sync.

## What's saved

Library and playback data stay on this Mac in `~/Library/Application Support/CoverFlow/`:
`Library.json` (collection, edits, play history), `Playback.json` (queue, position, shuffle,
repeat, volume) and `Artwork/` (original cover images). Audio files are read where they are —
never copied, moved or modified. Window layout and preferences use standard macOS defaults.
Last.fm is optional: connecting sends track metadata and listening timestamps to Last.fm.
`LastfmPending.json` stores pending listens locally; API credentials and the session key use Keychain.

## Keyboard

| Keys | Action |
| --- | --- |
| ← → / Home / End / Page Up/Down | Browse Cover Flow |
| Return / Space | Show tracks / pause or resume playback |
| ⌘P, ⌘→, ⌘← | Play/Pause, next, previous |
| ⌥⌘→ / ⌥⌘← | Skip ±10 s |
| ⌘↑ / ⌘↓ / ⌥⌘↓ | Volume up / down / mute |
| ⌃⌘S / ⌃⌘R | Shuffle / repeat |
| ⌘1 / ⌘2 | Cover Flow / Grid |
| ⌘3 / ⌘F | MilkDrop visualizer / search music |
| ⌘U / ⌘L | Queue / show playing album |
| ⇧⌘A | Album View; ⌥⌘1/2/3 Compact / Large / Immersive |
| In Album View | Space, ←/→, 1/2/3 sizes, F artwork focus, Esc exit Immersive / close |

## Brand assets

The app icon, README header and badges are generated by `scripts/make_brand.py`
(`python3 scripts/make_brand.py --version 1.2.0`), following the same layout as the other
dustalexw apps in Cover Flow's navy, ivory and brass.

## Demo collection

Five albums of original music synthesized on first launch, with procedurally drawn covers, all
labelled DEMO. Remove or rebuild them from the File menu or Settings.
