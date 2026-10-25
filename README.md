<p align="center"><img src="docs/readme-header.png" alt="Cover Flow — Only on macOS; browse your music by its covers" width="100%"></p>

<p align="center">
  <a href="https://github.com/dustalexw/cover-flow/releases/tag/v1.6.2"><img src="docs/badge-release.svg" alt="Release v1.6.2"></a>
  <a href="https://github.com/dustalexw/cover-flow/releases/download/v1.6.2/Cover-Flow-1.6.2-macOS.zip"><img src="docs/badge-download.svg" alt="Download the macOS app"></a>
  <a href="#download-the-macos-app"><img src="docs/badge-platform.svg" alt="Platform: macOS 14 or later, Apple silicon and Intel"></a>
</p>

# Cover Flow

A native macOS audio player built around browsing a record collection: a 3D Cover Flow,
a grid, and **Album View**, a player window that scales from a compact mini-player to an
almost full-screen cover.

An **iPadOS 17+ version** is available as a separate native Xcode target, with touch
Cover Flow, local music import, gapless playback, lyrics, native MDX karaoke,
Last.fm, artwork editing and an audio visualizer. See the [iPad guide](iPad/README.md)
for features, installation with your developer account and platform differences.

Choose **Cover Flow → About Cover Flow…** for the app version, feature overview,
credits, and links to releases, source code, and issue reporting.

Long track titles wrap in album track lists and the queue. Albums with titles too
wide for a two-column list use one wider column. Compact playback, Album View,
Lyrics and karaoke preparation headers scroll overflowing titles, pausing at both
ends; hovering shows the full title immediately. Titles that fit stay still, and
Reduce Motion disables automatic scrolling.

To remove an individual track, open its album, right-click the track and choose
**Remove from Collection…**, then confirm. It is also removed from the playback
queue. Your original audio file stays on disk; removing the last track removes
the empty album. On iPad, touch and hold a track for the same action; only the
app’s imported copy is deleted.

## Karaoke

Open **View → Karaoke** (⌘5) for lyrics, preparation and export.
The standard playback bar also has a paired **Karaoke** (crossed-out microphone)
and **Vocals Only** (microphone) control beside Lyrics. Click either to prepare
automatically and switch to that source when ready. A progress bar and percentage
appear below the icons; click progress for details and cancellation. Click the
selected icon again for **No Karaoke** (original audio). Changing modes during
preparation uses the latest choice; changing tracks prevents a delayed switch.
Prepared tracks switch immediately using their saved audio. Right-click the icons
to open the full Karaoke window.
Play or select a track, choose a **Model** in the Karaoke window, then click
**Prepare** on the bottom playback row. **Add model…** saves another model in the
selector; your selection is remembered between launches. Compatible files in
`Downloads/Otras` or `Downloads` are also discovered automatically.

Supported model families:

- **Becruily Deux and compatible Mel-Band RoFormer**: a `.ckpt` checkpoint and its
  matching `.yaml`/`.yml` configuration, with two stereo 44.1 kHz outputs in
  Vocals/Instrumental order. Uses Metal when available, with CPU fallback.
- **UVR MDX ONNX**, including **UVR-MDX-NET-Inst_HQ_5**: an `.onnx` file. Known
  models are recognized by their UVR fingerprint using the included parameter
  catalog. For another compatible vocal/instrumental MDX model, supply its matching
  UVR JSON settings when prompted. Processing prefers Core ML with GPU enabled,
  and falls back to CPU if conversion or prediction fails. Demucs, VR, MDX23C and
  multi-stem architectures require different processors and are not supported.

An MDX JSON can be a UVR fingerprint catalog or a single parameter object containing
`mdx_dim_f_set`, `mdx_dim_t_set`, `mdx_n_fft_scale_set`, `compensate` and
`primary_stem` (`Vocals` or `Instrumental`). The app validates settings and graph
shape instead of guessing. Imported MDX settings are copied to Application Support;
model weights remain at their selected location. Core ML conversion is automatic
on first preparation and saved in `Karaoke/ModelCache/MDX` for later tracks. The
conversion cache includes the model contents, settings and runtime version, so
replacing weights at the same path cannot reuse an outdated conversion. Audio
transforms and file handling stay on CPU; Core ML schedules supported model
operations across CPU/GPU. Existing prepared stems remain reusable.

Switching models returns playback to Original and uses that model's saved stems,
or enables preparation if the track is not ready yet. Each model has a separate
cache. Finish or cancel an active preparation before changing models. Processing
stays on your Mac, keeps the original audio unchanged, and shows progress while
music continues playing.

Once ready, choose **Karaoke** to hear the instrumental, **Vocals** to practice with
the separated voice, or **Original** to return to the recording. Switching retains
the playback position. The existing LRC lyric view follows the same clock; import
an LRC or place a matching sidecar beside the original track. Source separation
does not generate lyric text. Moving to a different track returns to original audio.

With the Karaoke window active, **Space** pauses or resumes playback, **1** selects
Original, **2** selects Karaoke, **3** selects Vocals, and **P** prepares the current
track. The mode and preparation buttons show their keys on the bottom playback row.
Shortcuts leave text editing and file dialogs alone. Karaoke and Vocals become
available after preparation finishes.

Prepared audio is saved under `~/Library/Application Support/CoverFlow/Karaoke`
and reused when the source and model are unchanged. **Export instrumental…** saves
a WAV copy. This release includes an Apple-silicon processing runtime and uses
CPU when Metal acceleration is unavailable. Model weights remain user-supplied.

## Download the macOS app

Download **Cover-Flow-1.6.2-macOS.zip** from the
[1.6.2 release](https://github.com/dustalexw/cover-flow/releases/tag/v1.6.2), unzip it, and move
**Cover Flow.app** to Applications. The universal app runs on Apple silicon and Intel Macs
with macOS 14 or later. Karaoke processing requires Apple silicon and your own
supported model files (see Karaoke above). The app is
ad-hoc signed rather than notarized, so the first time, right-click it and choose **Open**.

## What’s new in 1.6.2

**Individual track removal.** Open an album, right-click a track and choose
**Remove from Collection…**. Removal updates the playback queue and saved library,
and removes an album when its last track is removed. Original audio files stay
on disk; generated demo audio is deleted. The iPad project has the same action
in a track’s touch-and-hold menu, deleting only its imported copy.

**Long track titles.** Track lists and queues wrap long titles, while compact
playback headers scroll overflowing text with support for Reduce Motion.

**Native iPad project.** The source includes an iPadOS 17+ Xcode target with touch
browsing, Files/iCloud import, gapless playback, lyrics, karaoke, AirPlay, Last.fm
and visualizers. Build and sign it with your Apple Developer account; the macOS
download below is a separate desktop app.

**GPU-enabled MDX preparation.** Inst_HQ_5 and compatible MDX models now convert
locally to Core ML with GPU computation enabled. Converted models are saved for
reuse. If conversion or prediction fails, preparation retries on CPU and reports
that in progress. Becruily retains its Metal/CPU path.

**Karaoke model selector.** Save and switch between Becruily Deux, UVR MDX ONNX
models including Inst_HQ_5, and other compatible models. Preparation, progress,
source switching and instrumental export use the selected model. Saved stems are
kept separately for each model.

## What’s new in 1.5.0

**Karaoke and Vocals Only.** New icons beside Lyrics automatically prepare the
current track with your local Becruily Deux model, show progress, and switch when
ready. Click an active icon again to return to original audio. Prepared tracks
are cached, and the full Karaoke window provides synced LRC lyrics, source
switching, cancellation and instrumental export. Space pauses/resumes there;
1/2/3 selects Original/Karaoke/Vocals, and P prepares the track.

## 1.4.1

**Seamless window top.** The album backdrop now flows up behind the title and
toolbar instead of stopping at a grey title strip. In Grid view, albums scroll
cleanly under the toolbar edge.

**Ornate Stable Diffusion scenes.** Colors & Scene has a new **Subtle / Ornate**
style; Ornate (the default) paints decorative scenes from the cover's own colors and
imagery, continuing the cover outward. If refinement can't run, Colors & Scene now
says why instead of quietly falling back.

## 1.4.0

**Smoother album scenes.** Cover colors now spread into soft gradients instead of
long horizontal and vertical streaks, titles are removed more cleanly, mirrored
texture samples reduce visible repeats, and the area behind track names is calmer.
Scenes also generate and recolor faster. Existing scenes refresh automatically.

**Refine with Stable Diffusion** (Apple silicon). Each album’s **Colors & Scene**
editor can repaint its scene with the bundled Stable Diffusion 1.5 model, running
on this Mac’s Neural Engine. The first refinement of an album takes about 10–30
seconds and is then saved. It is off by default. The app download is larger
(about 1.5 GB) because it includes the model.

## Previous update: 1.3.0

**Lyrics** is a resizable window that follows the current track. Open it from the
lyric button in the collection or Album View, or press **⌘4**. Timed LRC lyrics
highlight the current line and scroll with playback; click a line to seek to it.
Turn **Follow playback** off to browse the lyrics freely.

Cover Flow automatically reads a matching sidecar: `Song.flac` uses `Song.lrc`
in the same folder, including uppercase `.LRC` extensions. **Import LRC…** saves
a local copy for the current track; imports remain available after restarting.
**Reload lyrics** reads edits made to the file. UTF-8 and UTF-16 text, repeated
timestamps, translations sharing a timestamp, millisecond timing, blank instrumental
breaks, and `[offset:…]` tags are supported. Positive offsets advance the lyric
highlight; negative offsets delay it. Untimed LRC text is displayed without syncing.
Lyrics stay on this Mac; no online lyric service is used.

The album action menu now draws its three dots above the native menu control so
macOS cannot discard their custom label. The button keeps the same album actions.

## Previous update: 1.2.3

Album scenes now render at **2160 × 1320 pixels** for crisp Retina backgrounds,
using up to 768 pixels of cover detail instead of 192. Broad cover colors extend
smoothly, while fine texture grows outward with minimum-error seams and narrow
feathering. This reduces block-shaped color changes, patch joins, and ghosted edges.
Detected faces, prominent subjects, and lettering are excluded from texture samples;
repeated use of the same patch is discouraged.

Existing scenes refresh automatically the next time an album is opened. Colors,
scene strength, and saved variations are retained. Scenes still generate locally,
stay still, and protect text contrast. The larger scene cache is bounded in memory.

## Previous update: 1.2.2

The album track panel’s menu uses three equally sized dots on one horizontal line.

**Replace Artwork** now embeds the selected cover in every writable MP3, M4A/M4B,
MP4, FLAC, WAV, and AIFF/AIFC file belonging to the album. Existing audio is not
re-encoded. Each file is updated through a verified temporary copy, then replaced
atomically. Other tags and labelled back covers/booklets are preserved.

Cover Flow reports how many files were updated and lists failures, including
locked, missing, damaged, and unsupported files. The library cover still updates
when some files cannot accept embedded artwork. JPEG/PNG covers retain their
original bytes when suitable; other image formats are converted to a compatible
JPEG for embedding. **Remove Artwork** removes the library cover only.


Each album’s track panel has its own **Colors & Scene** editor. Choose background,
text, and accent colors with native color pickers or hex values. A live preview
shows the result before you save; Cancel leaves the album unchanged.

Static, content-aware scenes extend the shapes, textures, and colors of the cover.
They are generated on your Mac, cached as still images, and kept quieter behind
track names. Contrast protection keeps custom text and accents readable. Choose
scene strength, regenerate a variation, turn the scene off, or **Reset to Cover**.
The settings apply only to that album’s track panel. New artwork refreshes its scene.

On Apple silicon, **Refine with Stable Diffusion** repaints an album’s scene with the
bundled Stable Diffusion 1.5 model (Apple’s 6-bit Core ML version, run on the Neural
Engine). Choose a style from the **Stable Diffusion** menu: **Extend** (the default)
continues the cover past its edges in the same style, as if the artwork were larger;
**Subtle** keeps the generated scene’s look and smooths it; **Ornate** repaints the
surroundings as decorative imagery in the cover’s own colors. The first refinement of an album takes about 10–40 seconds and is
then saved; the model unloads after 90 idle seconds. Refinement is off by default and
runs entirely on your Mac. If it can’t run, or the model’s safety checker flags a
result, the editor says why and the regular scene is used instead.

The app and MilkDrop remain universal for Apple silicon and Intel. The Dock icon
restores a closed collection window, including with Album View or MilkDrop open.

## Build & run

Double-click **build.command** in Finder (or run `./build.command` in Terminal). It compiles a
universal release build with the Swift toolchain from Xcode, assembles **Cover Flow.app** next to the
script, signs it for local use and launches it. Requires macOS 14 or later and Xcode (or the
Command Line Tools). You can drag `Cover Flow.app` into /Applications.
The first build downloads verified projectM 4.1.8 and TagLib 2.3.2 source, the Stable Diffusion
model (about 1.6 GB, checksum-verified) and, if needed, a local CMake tool. Later builds reuse them.
No Homebrew installation is required. Run `COVERFLOW_SKIP_SD=1 ./build.command` to build without
the model; scene refinement is then hidden.
Use `./build.command --no-launch` to assemble the app without launching it.
The app, TagLib, and projectM are built for `arm64` and `x86_64`; the build verifies
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

Mono and stereo **Opus** files (`.opus`, or Opus in `.ogg`/`.oga`) import and play like
any other track, gaplessly, with encoder delay and end padding trimmed. Their tags and
embedded cover art are read, **Replace Artwork** can embed covers in them, and karaoke
preparation accepts them. Opus is decoded by macOS's own decoder; surround Opus and Ogg
Vorbis files are listed as unsupported in the import report.

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
| `Library` | Import, metadata (AVFoundation + small FLAC and Ogg Opus readers), album grouping, artwork cache, persistence, demo collection |
| `Playback` | `PlayerEngine` — queue, shuffle/repeat, seeking, volume, errors, Now Playing + media keys |
| `Scrobbling` | Last.fm authorization, Keychain credentials, listening progress and durable retry queue |
| `Views` | Cover Flow, grid, album sheet, editor, queue, player bar, settings |
| `AlbumView` | Album View window controller (presets, resize, position memory) and its content |

Playback, metadata, collection state and presentation are separate objects, so each can change
without touching the others. Every view observes the same `PlayerEngine`, which keeps state in sync.

## What's saved

Library and playback data stay on this Mac in `~/Library/Application Support/CoverFlow/`:
`Library.json` (collection, edits, play history), `Playback.json` (queue, position, shuffle,
repeat, volume) and `Artwork/` (original cover images). Audio files are referenced in place.
Replacing album artwork writes the cover into supported audio files; text edits and
removing a library cover affect the library only. Imported lyrics are copied into `Lyrics/` and do not change audio files or their sidecars. Window layout and preferences use standard macOS defaults.
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
| ⌘3 / ⌘4 / ⌘F | MilkDrop visualizer / lyrics / search music |
| ⌘U / ⌘L | Queue / show playing album |
| ⇧⌘A | Album View; ⌥⌘1/2/3 Compact / Large / Immersive |
| In Album View | Space, ←/→, 1/2/3 sizes, F artwork focus, Esc exit Immersive / close |

## Brand assets

The app icon, README header and badges are generated by `scripts/make_brand.py`
(`python3 scripts/make_brand.py --version 1.3.0`), following the same layout as the other
dustalexw apps in Cover Flow's navy, ivory and brass.

## Demo collection

Five albums of original music synthesized on first launch, with procedurally drawn covers, all
labelled DEMO. Remove or rebuild them from the File menu or Settings.
