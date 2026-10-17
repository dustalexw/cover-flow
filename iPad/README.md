# Cover Flow for iPad

A native iPadOS 17+ version of Cover Flow, with a separate Xcode application target.
The desktop app remains in the same repository; shared playback, metadata, lyrics,
queue ordering and Last.fm code stay shared.

## Install with your developer account

1. Open `CoverFlow-iPad.xcodeproj` in Xcode.
2. Select **CoverFlowiPad → Signing & Capabilities**, enable automatic signing,
   and choose your Apple Developer team. Change the bundle identifier if your
   account needs a different identifier.
3. Connect your iPad, select it as the run destination, and press **Run**.

The prepared project download includes Microsoft's native runtime. From a fresh
Git checkout, run `../build-ipad.command --project` first to fetch the verified
runtime and open the project. No Python runtime or user separation weights are
included in the iPad app. The project generator preserves a selected team and
bundle identifier when regenerated.

The supplied device build is unsigned; it cannot be installed by opening a ZIP on
an iPad. Signing and installing through Xcode uses your own developer account.

## Features

| Feature | iPad version |
| --- | --- |
| Cover Flow | Touch carousel, 3D covers and reflections, reduced-motion support |
| Collection | Adaptive grid, search across albums/artists/tracks, sorting, multi-album selection |
| Music import | Files, iCloud Drive and attached drives; recursive folder import, duplicate detection, format/error reporting |
| Local library | Owned audio copies, original filenames and matching LRC sidecars; persistent library and playback queue |
| Playback | Shared gapless engine, queue ordering, shuffle, repeat, seek, volume, mute and upcoming-track editing |
| System audio | Background audio capability, lock-screen/Control Center commands, AirPlay routing and interruption/headphone handling |
| Album View | Full Now Playing sheet, large artwork and artwork focus; long titles wrap or scroll in the compact bar |
| Artwork | Embedded/folder covers, photo-picker replacement, library artwork removal and bounded thumbnail cache |
| Album customization | Title/artist/year/genre and track edits in the library; calm artwork scenes, background color, strength and variations |
| Lyrics | Shared UTF-8/UTF-16 LRC parser, offsets, repeated timestamps/translations, line seeking, follow toggle, import and reload |
| Karaoke | Native MDX ONNX processing, including Inst_HQ_5; Core ML GPU preference and CPU fallback; saved model selector |
| Karaoke controls | Original/Karaoke/Vocals Only, automatic preparation, progress, cancellation, per-model saved stems, instrumental/vocal export |
| Becruily audio | Import the Mac app's prepared stereo 44.1 kHz `vocals.wav` and `instrumental.wav` for a matching track |
| Converted models | Native Core ML waveform-model support with the contract below |
| Visualizer | Three audio-reactive native spectrum/orbit/ribbon styles, automatic switching and reduced-motion handling |
| Last.fm | Setup, browser authorization, Keychain credentials, Now Playing, listening-based scrobbles and pending retries; off until connected |
| Demos | Three original generated demo albums with artwork and timed lyrics |

The visualizer uses native drawing in place of desktop OpenGL/projectM, and does
not import `.milk` presets. Stable Diffusion scene refinement is not included in
this initial iPad version. Artwork and metadata edits affect the iPad collection;
embedded audio-file tag writing is not included. Protected Apple Music streaming
and DRM files are not imported as playable audio.

## Music and lyrics

Use **Import Music → Audio files** or **A folder**. Files must be readable/downloaded
through their provider; failures appear in the import report. Imported copies
remain playable if you later remove the source or disconnect its drive. Removing
an album deletes its iPad-owned music, imported lyrics, covers and prepared audio.
Source files outside the app remain owned by their original provider.

Import a folder to include matching `Song.lrc`/`Song.LRC` sidecars automatically.
For an individual track, open Lyrics and choose **Import LRC…**. Lyrics are supplied
by the user; separation does not generate lyric text.

## Native karaoke

In **Karaoke → Add → Add Model…**, import `UVR-MDX-NET-Inst_HQ_5.onnx` or another
compatible vocal/instrumental MDX ONNX model. Known weights are identified by their
UVR tail fingerprint using the same parameter catalog as the Mac app. An unknown
model prompts for its matching UVR JSON settings. Drum/bass, VR, Demucs and MDX23C
architectures are not accepted as two-stem MDX models.

Tap Karaoke or Vocals Only to prepare automatically and switch when ready. Model
conversion happens locally on first use, with Core ML configured for CPU/GPU.
Converted models are reused across tracks and keyed by model contents, settings
and runtime version. Core ML schedules the actual compute devices; transforms and
file handling run on CPU. If model conversion or prediction fails, MDX retries on
CPU. Keep Cover Flow open during preparation. Cancellation interrupts ONNX runs;
Core ML compilation may finish its current system call before stopping.

Models and Imported Stems have separate entries in the selector. Switching returns
to Original and loads the selected model's saved audio. Removing a model also
removes its owned weights and prepared audio when no other entry uses those weights.
Audio caches are separate from disposable conversion caches and temporary jobs.

Raw PyTorch `.ckpt` files, including Becruily Deux, cannot run in this iPad app.
Prepare on the Mac and transfer both resulting WAV files, then choose **Import
Prepared Stems…** on iPad. Select files named `vocals.wav` and `instrumental.wav`.
They must both be stereo 44.1 kHz and match the current track's full duration.

### Converted Core ML waveform contract

A separately converted `.mlmodel`, `.mlpackage` or device-compatible `.mlmodelc`
can be imported if it has:

- One float32 stereo waveform input shaped `[1, 2, N]`, with static
  `8192 <= N <= 1048576`.
- One floating-point output shaped `[1, 2, 2, N]` in Vocals/Instrumental order.
- Creator-defined metadata `coverflow.stem_order = Vocals,Instrumental` and
  `coverflow.sample_rate = 44100`.

Preparation applies padded overlapping windows, normalizes the overlap weights,
retains exact frame counts and uses shared gain if needed to avoid clipping.
This is an import contract, not a general PyTorch-to-Core-ML converter or a claim
that arbitrary checkpoint architectures can be converted unchanged.

## Build and verify

```
../build-ipad.command --device
../build-ipad.command --simulator
swift test --disable-sandbox
```

Both build commands produce unsigned development artifacts. For a normal signed
build, use the Xcode project's Signing & Capabilities and Run/Archive actions.
`COVERFLOW_COMPILER_SANDBOX_WORKAROUND=1` adds Swift's compiler-plugin sandbox
workaround only when nested CI/agent sandboxes otherwise block macro expansion.

The core test package runs on macOS and exercises the same Swift/Objective-C++
processing implementation compiled into the iPad app. Set `IPAD_TEST_MDX_MODEL` to
a local Inst_HQ_5 ONNX file to enable actual inference. The spectrum fixture was
generated with the Mac processor's PyTorch STFT. `SplitFixture.mlmodel` is a tiny
30/70 gain-split test model with no trained weights; it is not included in the app.
See [verification notes](../docs/ipados-verification.md) for test evidence and
remaining physical-device checks.

Microsoft ONNX Runtime 1.24.2 and its notices are included under its MIT license.
The app's privacy manifest declares its local preferences, file metadata, disk-space
checks and elapsed-time measurements. Last.fm is optional and sends listening
metadata only after the user configures and connects it. Audio/model files stay local.
