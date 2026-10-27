# Demucs and Stem Mix — 1.8.0 validation

Implemented on macOS: six-stem HTDemucs, four-stem HTDemucs, HTDemucs fine-tuned,
Hybrid Demucs and Demucs MDX Extra; local unquantized safetensors import;
automatic preparation from the playback-row isolation icons; and a Karaoke
Stem Mix section with independent levels, mute, multi-solo, reset and WAV export.
Legacy Becruily and UVR MDX preparation and saved two-stem caches remain compatible.

Model downloads use the official maintainer's repositories, pinned revisions,
expected sizes and SHA-256 verification. Downloads are atomic and cached outside
transient jobs. Inference uses disk-backed overlap-add, bounded chunks, exact
input frame counts, all model outputs and one shared gain. Instrumental is the
sum of every non-vocal stem. Downloaded or imported files are never unpickled;
only known Demucs architectures can be constructed from safetensors metadata.

Live mixing decodes each stem on the same sample timeline. Separate playback
nodes share a clock and feed the visualizer through the mixed output. Changing
a gain does not rebuild the queue or wait for the decoder's lookahead. Switching
sources retains time and the playing/paused state.

Verification on this Mac:

- Full Swift suite: 99 tests, zero failures. Eleven sandbox-dependent checks
  skipped (audio components, GPU and optional external legacy models).
- All eight gapless/live audio tests rerun with Core Audio access: zero failures.
  Includes immediate gain changes, pause, seek, ordinary track transitions, and
  opposite-polarity 440 Hz stems cancelling after pause/resume and seek.
- Python suite: 13 tests, zero failures, covering two/six-stem overlap-add, short
  and multi-window inputs, frame coverage, metadata restrictions and MDX fallback.
- Official six-stem model ran on CPU and Apple GPU (MPS), producing seven finite
  stereo 44.1 kHz WAVs (six stems plus instrumental), each exactly 88,200 frames.
- Each of the four other built-in models processed the same generated two-second
  input on CPU, producing all four stems and instrumental at the exact length.
- Universal arm64/x86_64 macOS release build and strict code-signature validation.
- Generic iPad device release build succeeds with the shared player changes.
- Isolated preview app: guitar click selected the six-stem model, showed progress,
  downloaded weights, saved all stems and selected guitar. Mixer controls, level
  changes, solo, model menu, saved-cache reload and Space play/pause were verified.
  The karaoke window keeps playback controls inside its content area. Only a
  generated test collection was used; the user's music collection was unchanged.

Demucs processing and the new mixer UI are Mac features; inference requires the
bundled Apple silicon Python runtime. The iPad retains its existing native MDX
and Core ML workflows. Six-stem guitar/piano separation is experimental, with
possible instrument bleed. Legacy pickle and quantized Demucs checkpoints are
not imported. Tests establish processing and synchronization, not subjective
separation quality for every recording. Before release, current main's 1.7.0 Opus/FFmpeg decoder updates were merged,
then the universal Mac app and both iPad device/simulator targets were rebuilt.
The merged full Swift suite passed: 110 tests, three optional external-model
integration checks skipped, zero failures. Python inference tests also passed
(13 tests). The artwork preservation test now uses explicit sRGB pixels and
compares stored bytes, avoiding AppKit's display-profile-dependent NSColor
conversion while checking two distinct preserved artwork regions. The release
app's bundled shared decoder libraries, LGPL source, version 1.8.0/build 27,
code signature and ZIP contents were verified.

The standalone iPad Swift package also passed (10 tests, one optional model test
skipped). Its shared stem types now live in Core and are linked into the Mac
target, so both the package and Xcode project compile the same definitions.
The Mac target and both iPad app targets were rebuilt after this configuration
fix; the shared type contents and Mac runtime behavior are unchanged.
