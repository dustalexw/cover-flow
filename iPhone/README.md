# Cover Flow for iPhone and iPhone Duo

Open **CoverFlow-iPhone.xcodeproj**, select **CoverFlowiPhone**, choose your iPhone
or an iPhone simulator, and Run. For a physical phone, select your Apple Developer
team under **Signing & Capabilities** first. Requires iOS 17 or later.

From a fresh Git checkout, run `../build-ios.command --project`. It fetches the ONNX
Runtime, builds FFmpeg and TagLib for iOS (`../scripts/build-ios-native.sh`, a few
minutes the first time, then cached), generates the project and opens it. Keep the
unzipped or checked-out folder together: this project shares sources and resources
with `../iPad` and `../Sources`.

Build with **Xcode 27.1 or later** to include iPhone Duo's fold-aware layouts. Older
Xcode versions build the same app without the fold APIs; on iPhone Duo it then
behaves as if the inner display were always flat.

## iPhone Duo

Cover Flow lays out by size class, never by device type or orientation, so each
display gets the layout that fits it:

| Display and pose | Size classes | Cover Flow |
| --- | --- | --- |
| Outer display, closed | Compact width | Phone layout: Collection, Up Next, Lyrics and Karaoke tabs with Visualizer and Settings under More, and the mini-player above the tabs |
| Inner display, open flat | Regular × regular | Mac-like layout: sidebar, Cover Flow or Grid with the album's tracks beside it, and a full-width player bar |
| Inner display, book (fold vertical) | Regular × regular | Two pages: covers on the left, the album panel on the right. The sidebar tucks away (tap the sidebar button to show it). The player bar keeps track info on the left page and every control on the right page |
| Inner display, tabletop (fold horizontal) | Regular × regular | **Album View stands up**: artwork, titles and the current lyric lines above the fold; transport, volume, karaoke and stems below it. **Browse** returns to the collection until you change pose |

Details:

- **Nothing straddles the fold.** Pane boundaries, the player bar, Album View, the
  Karaoke page (controls on one page, lyrics on the other) and Immersive Album View
  (cover on one page or above the fold) read the fold from SwiftUI's reserved
  regions. Grids in book posture use an even number of columns.
- **Folding and unfolding keeps your place.** The selected tab, focused cover,
  playback and Album View carry over. An album open in a sheet on the outer display
  moves into the side panel when you unfold; folding again doesn't pop a sheet up.
- **Hinge effect.** Partly folded like a laptop, the covers lean back slightly with
  the hinge angle, like records on a shelf. It is only an effect: layout never
  depends on the angle, and Reduce Motion turns it off.
- **Keyboard.** With a hardware keyboard, the Mac's shortcuts work (see below).

Large iPhones in landscape report regular width but compact height and keep the
phone layout. iPad uses the same expanded layout as the inner display.

## Parity with the Mac app

| Mac feature | iPhone / iPhone Duo |
| --- | --- |
| Cover Flow, Grid, search, sort, multi-album selection | ✓ Touch, plus ← → Home End Page Up/Down and Return with a keyboard |
| Album track panel | ✓ Beside the covers on the inner display; a sheet on the outer display |
| Album View: Compact, Large, Immersive | ✓ Player bar, Album View sheet, and full-screen Immersive with auto-hiding controls, F for artwork focus and Escape to close |
| Immersive artwork scenes | ✓ Same scene generator as the Mac, around the cover's actual position; regenerated per layout and pose |
| Gapless playback, queue, shuffle, repeat | ✓ |
| Formats: Opus, Vorbis, Speex, Monkey's Audio, WavPack, WMA, DSD, Musepack, TTA, TAK, Shorten, DTS, Wave64, Matroska/WebM | ✓ With the iOS FFmpeg build (`build-ios-native.sh`); Opus and the system formats otherwise |
| Replace Artwork embeds the cover in audio files | ✓ With the iOS TagLib build, in the app's imported copies only (never in Files/iCloud originals) |
| Find Lyrics / Artwork Online | ✓ |
| Synced lyrics, offsets, line seeking | ✓ |
| Karaoke: MDX ONNX incl. Inst_HQ_5, Core ML | ✓ Native, Core ML GPU with CPU fallback |
| Demucs instruments and Stem Mix | ✓ Playback, isolation buttons, Stem Mix (levels, mute, multi-solo, reset) and stem export for Demucs sets prepared on the Mac and imported (**Karaoke → Add → Import Prepared Stems or Demucs Set…**, choose the stem WAVs or their folder) |
| Visualizer: four Metal styles, Auto, full screen, ← → | ✓ |
| Last.fm | ✓ |
| Keyboard shortcuts | ✓ ⌘P, ⌘← ⌘→, ⌥⌘← ⌥⌘→, ⌘↑ ⌘↓, ⌥⌘↓, ⌃⌘S, ⌃⌘R, ⌘1–⌘5, ⌘U, ⌘L, ⌘F, ⇧⌘A, ⌥⌘1/2/3, ⌘, |
| About Cover Flow | ✓ Settings → About Cover Flow |

Not available on iPhone, and why:

- **Running Demucs or Becruily (PyTorch) separation on the phone.** These need the
  Mac's Python/PyTorch runtime. Prepare on the Mac and import the stems; MDX ONNX
  and converted Core ML models do run on the phone.
- **MilkDrop / projectM presets.** projectM targets desktop OpenGL; the four native
  Metal styles are available instead.
- **Stable Diffusion scene refinement** (Extend/Subtle/Ornate). The 1.6 GB Mac
  model isn't suited to a phone; immersive scenes use the same non-AI generator the
  Mac uses before refinement.
- **Keep media organized.** Not needed: the app always keeps its own copies.

## Keyboard

| Keys | Action |
| --- | --- |
| ← → / Home / End / Page Up/Down, Return | Browse Cover Flow, open the album |
| ⌘P | Play/Pause |
| ⌘→ / ⌘← | Next / previous track |
| ⌥⌘→ / ⌥⌘← | Skip ±10 s |
| ⌘↑ / ⌘↓ / ⌥⌘↓ | Volume up / down / mute |
| ⌃⌘S / ⌃⌘R | Shuffle / repeat |
| ⌘1 / ⌘2 | Cover Flow / Grid |
| ⌘3 / ⌘4 / ⌘5 | Visualizer / Lyrics / Karaoke |
| ⌘U / ⌘L / ⌘F / ⌘, | Up Next / show playing album / search / Settings |
| ⇧⌘A; ⌥⌘1/2/3 | Album View; Compact / Large / Immersive |
| In Immersive Album View | Space, ← →, F artwork focus, Escape close |
| In Karaoke | 1/2/3 Original/Karaoke/Vocals, P prepare |

Features and native model requirements are documented in [the mobile guide](../iPad/README.md).
