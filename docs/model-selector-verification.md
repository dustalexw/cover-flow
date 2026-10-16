# Karaoke model selector — October 16, 2026

Local build 1.6.0 (24) adds a saved model list and menu in View → Karaoke.
Add model accepts UVR MDX ONNX or compatible two-stem Mel-Band RoFormer
checkpoint/YAML pairs. Existing Becruily preferences and caches are retained.
The selected model has its own cache; switching clears pending playback requests,
returns playback to Original through the window, and restores the selected
model's saved audio. Selection is disabled until preparation finishes or is cancelled.
MDX settings are copied outside the application bundle to survive app moves/updates.
Weights remain external and all inference remains local.

The MDX processor validates the model fingerprint/settings and ONNX graph,
packs stereo complex spectra, runs CPU inference with sign-inverted denoising,
and reconstructs exact-length stems through 50% overlapping Hann windows. It
uses disk-backed audio buffers and shared gain if needed to avoid clipping.
Known parameters come from the revision recorded in Karaoke/MDX-SOURCES.txt.
Unknown compatible MDX models require a matching JSON parameter file. This is
not support for arbitrary ONNX architectures, Demucs, VR or MDX23C models.

Verified real model files:

- Becruily Deux SHA-256:
  `10255c02295bf3e3865d4ee50ff752d7b19b124ed5fd93b147babc4333eda3aa`.
- UVR-MDX-NET-Inst_HQ_5 SHA-256:
  `811cb24095d865763752310848b7ec86aeede0626cb05749ab35350e46897000`.
  UVR tail fingerprint: `cb790d0c913647ced70fc6b38f5bea1a`.
  Graph: float32 `[batch, 4, 2560, 256]`; FFT 5120, hop 1024,
  primary Instrumental, compensation 1.01.

The full Swift suite passes: 78 tests, five audio-environment skips, zero failures.
New checks cover fingerprint and custom parameter validation, legacy migration,
saved selection and deduplication, stable copied settings after deleting the
original JSON, separate model caches, selection locking during preparation, and
real MDX preparation through the Swift store/process bridge. Becruily also runs
through the existing real-model integration. Output sample rate, channel count,
exact frame counts, model SHA and unchanged original bytes are checked.

Seven Python checks pass, including stereo spectrum round trips, short/long/silent
and edge-impulse overlap reconstruction, invalid MDX parameters and graph shapes,
existing RoFormer overlap behavior, safe YAML and incompatible stem order.
These use short synthetic inputs and establish execution/data integrity, not
measured vocal separation quality on songs or validation of every catalog model.

The native player and visualizer build for Apple silicon and Intel. Karaoke
processing remains Apple-silicon-only; MDX uses CPU, while RoFormer retains its
automatic Metal/CPU path. The packaged runtime includes pinned ONNX Runtime and
license notices. The bundle passes deep signing verification, including after
Python tests run with bytecode generation disabled. Scene assets are retained.

The production KaraokeView was rendered offscreen in light/dark mode at its
540-point minimum width, using inert playback/lyrics fixtures. The model name,
Add model action and preparation/cancellation layout fit. ImageRenderer cannot
render the native progress control, so its bitmap is not evidence of live progress
appearance. Live device playback, model-menu interaction, Metal and long-song
separation quality still require a desktop listening check.
