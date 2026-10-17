# iPadOS port verification — October 16, 2026

The native iPad app targets iPadOS 17+, version 1.0.0 (1), and builds from
`iPad/CoverFlow-iPad.xcodeproj`. It shares the desktop PCM decoder, gapless engine,
player, playback ordering, models, metadata/FLAC reader, scrolling-title component,
LRC parser/store, Last.fm API/Keychain/scrobbling logic and visualizer audio buffer.
AppKit-specific file pickers/windows are replaced by native SwiftUI/UIKit views.
The macOS app retains its existing target and processing runtime.

Completed release builds:

- Generic iPad device: arm64, iPhoneOS SDK, unsigned.
- Generic iOS Simulator: arm64 and x86_64, iPhoneSimulator SDK, unsigned.
- The bundle declares iPad device family, minimum iOS 17, all four iPad orientations,
  background audio, file opening, native app icons, privacy manifest and runtime
  licenses/notices. It includes no Python interpreter, PyTorch checkpoint, ONNX
  separation weights, Stable Diffusion weights, or test-model fixture.

The portable core package passes **10 tests with zero failures**, including:

- Stereo FFT 5120 packing and inverse reconstruction with edge impulses.
- Packed spectral values against the desktop PyTorch STFT reference.
- Parameter limits, selected-profile catalog decoding and unknown-model rejection.
- Recursive audio discovery, duplicate paths, unsupported files and hidden files.
- Owned file copies, Unicode filenames, uppercase LRC sidecars, deletion of the
  original source, and rebasing media paths to a restored sandbox container.
- Cancellation preventing a completed job from committing saved audio.
- Actual Inst_HQ_5 inference through the same Objective-C++ ONNX Runtime bridge
  compiled into the iPad app, finite exact-length stereo stems and unchanged source.
- Native Core ML waveform inference with a tiny 30/70 split fixture, verifying
  waveform-model input/output layout, stem order, exact frames and reconstruction.

Actual Inst_HQ_5 weights used for inference have SHA-256
`811cb24095d865763752310848b7ec86aeede0626cb05749ab35350e46897000` and UVR tail
fingerprint `cb790d0c913647ced70fc6b38f5bea1a`. The local model integration receives
that file through `IPAD_TEST_MDX_MODEL`; weights are not committed or bundled.
The tiny Core ML test fixture contains no trained weights and is test-only.

The desktop suite also passes after shared-source adaptations: **78 tests, five
existing audio-environment skips, zero failures**. Source changes use platform
conditions for AppKit/UIKit, Now Playing playback-state APIs, iPad audio session
activation and metadata refresh; the desktop implementation remains selected on macOS.

Import ownership is intentional on iPad: security-scoped Files URLs are held only
for import, provider reads are coordinated on iOS, and audio/lyric copies live in
the app container. Imported audio allows access after the first device unlock for
background playback. Artwork thumbnails have an 80 MB cache limit. Model weights
are app-owned; conversion caches are excluded from backup and keyed by weight
contents, parameters and runtime version. Temporary jobs are cleaned on cancellation
or next launch, and album removal also purges owned covers, lyrics and prepared audio.

Karaoke selection is locked during processing/import; requests on a different track
cannot attach to the running job. Source requests use the latest requested mode,
returning to Original clears pending switches, and completion checks track/model
identity before applying the new audio. Track changes and album removal clear/cancel
relevant work. Stem import runs off the main thread and requires two stereo 44.1 kHz
files matching each other and the selected track's duration.

Remaining physical-device verification:

The installed Simulator service is out of date/unavailable in this session; builds
succeed, but no simulator UI session was available. The test process also exposes
no Metal GPU. Native Core ML conversion/execution and CPU output integrity are
verified, not actual iPad GPU throughput or live playback. No signing identity is
available to this session. Select the user's developer team in Xcode, then Run on
an iPad to verify the full touch layout, portrait/landscape and Split View resizing,
Files/iCloud providers, gapless/background/lock-screen audio, interruption and AirPlay
routes, long-title animation, photo imports, LRC following, model selection,
preparation/cancellation/export and Last.fm browser authorization.

The iPad feature guide documents platform differences: native visualizer styles
replace projectM/MilkDrop, Stable Diffusion refinement and embedded tag writing are
not included, and raw Becruily checkpoints use Mac-prepared stem import. Converted
Core ML waveform models must meet the documented shape/metadata contract; there is
no general checkpoint converter in the iPad app.
