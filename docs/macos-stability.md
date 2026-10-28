# macOS stability work

The supplied audit was checked against v1.8.0 and the actual failed Actions logs.
The Mac audio library is already a separately built, universal, replaceable LGPL
shared dependency. The iPad does not link it. Playback already uses an actor to
decode off the main thread and schedules at most eight seconds ahead; the audio
render callback does not demux files. Its visualizer handoff uses a non-blocking
try-lock and can drop visualization samples without dropping playback audio.

The most recent Mac and iPad CI failures were a Swift 6.1 type-checking timeout in
VisualizerSignal, not missing FFmpeg architecture slices. The FFT expression is
now split into explicitly typed intermediate values. Both workflows select Xcode
16.4 on macos-15, report the toolchain, and cancel superseded branch/PR jobs.
The Mac workflow fails on a test failure rather than retrying the whole suite.
Verified dependencies are saved before tests, so a product-test failure does not
throw away a successful native build.

## Playback and native ownership

- The decode pump holds its player only for one iteration, avoiding a retain
  cycle between a discarded player and its own long-running task.
- Each player load owns a cancellation token. Seek, replacement, stop and teardown
  cancel obsolete work, including a FFmpeg open that has not returned a PCM actor.
  FFmpeg's I/O interrupt callback and decode loops observe this token. The Swift
  wrapper retains its callback context through close and reports CancellationError.
- Swresample's planar conversion storage grows when necessary and is reused across
  frames, rather than allocating/freeing it for every decoded frame. The existing
  FIFO and AVAudioEngine scheduling preserve sample ownership and bounded lookahead.
- Packet ownership survives until a successful send or explicit rejection; decoder backpressure cannot
  silently discard a packet. EOF explicitly drains the decoder and resampler. I/O
  errors are reported instead of being treated as a successful end of track.
- Reset discards queued frames, packets and resampler state; close releases the
  scratch planes, FIFO, codec and container as well. FFmpeg log initialization is synchronized once. Codec
  worker count is bounded at two per instance. Invalid native buffer arguments and
  non-finite seeks are rejected; extreme finite positions are bounded before
  integer conversion instead of trapping Swift.

Pause and explicit synchronization publish the exact stopped/render position,
rather than waiting for the next UI poll. This prevents a delayed clock jump after
pausing during UI load and makes source switches use the current audio position.
Callback generation checks protect against observers replacing the source.

## Artwork

A dedicated actor performs ImageIO thumbnail/full-cover decoding. Requests for the
same immutable artwork version reuse decoded pixels, different covers cannot fan
out into unbounded decode jobs, and canceled queued requests skip file opening.
CGImage pixels cross the boundary as immutable values; NSImage construction stays
on the main actor. A synchronous cache lookup never opens files or decodes images.

Decoded cache storage has hard budgets of 192 MiB for browsing thumbnails and
96 MiB for full covers, with least-recently-used eviction. Large full-cover releases
happen outside the lock used by UI lookups. These limits cover cached pixel bytes;
visible view images, GPU textures and temporary ImageIO working memory are separate.
Original artwork files and their resolution are unchanged.

## Reproducible decoder build

The verified FFmpeg source and existing macOS-only dynamic-library layout are kept.
Cache identity now includes the compiler, SDK and build/verification scripts. Both
CPU slices, macOS platform, headers, install names and portable dependencies must
pass validation before a cached runtime is used. A new installation is staged and
validated before replacing the old one; interruption/failure preserves the working
runtime. Build parallelism has a bounded default and a COVERFLOW_BUILD_JOBS override.

## v1.8.1 validation baseline

- Full local Mac suite on Apple silicon and Intel/Rosetta with Core Audio/GPU
  access: **120 tests, zero failures**;
  three optional external-model integrations skipped. Includes real gapless/stem
  playback, rapid load/seek replacement, cancellation, invalid seeks, artwork
  concurrency/deduplication, off-main decoding and hard cache-budget eviction.
  A 24-bit/192 kHz six-channel WavPack fixture checks downmixing and sample counts.
- Native stress harness: **1,200 open/read/close lifecycles, 6,000 seeks**, plus
  cancellation and truncated/invalid-input cleanup, over eight real codec fixtures.
  AddressSanitizer and UndefinedBehaviorSanitizer reported no errors in the C bridge.
  FFmpeg shared libraries themselves are not sanitizer-instrumented.
- macOS leaks on the same stress harness: **0 leaks / 0 leaked bytes detected**.
  Only the generated test harness was given a debug entitlement for inspection;
  app entitlements and system protections were not changed.
- Rebuilt and verified both FFmpeg slices; a repeat build validates and reuses the
  cache. The native stress check is now part of Mac CI.
- Universal Mac app build and strict code-signature validation pass.
- iPad device build passes with the shared player changes.

These checks exercise the included codecs and failure cases; they do not guarantee
all damaged files or all physical audio devices are failure-free. The published
v1.8.0 release is not modified by this development work.

## Follow-up to the v1.8.1 audit

Verified the released implementation before changing the transport: playback uses
AVAudioPlayerNode with bounded prebuffering, artwork pixels already decode on a
background actor, and FFmpeg remains a macOS-only universal shared dependency.
No AVAudioSourceNode/ring-buffer or cross-platform XCFramework rewrite is needed
for these fixes.

- Unknown-duration streams such as Musepack previously decoded to EOF on every
  open. A bounded, session-only LRU now reuses the measured frame count for an
  unchanged file. Path, device, inode, size, nanosecond mtime and ctime identify
  each revision; changed/replaced files are probed again. The first uncached open
  still counts the samples, preserving accurate seeking and end-of-track timing.
  The native bridge rejects hints with a different sample rate.
- Opus playback traverses OpusTags lacing without copying the comment/artwork
  payload. Import still reads all tags. Audio packet storage, compressed input and
  decoded output buffers are reused; changing Opus packet duration creates a new
  converter as before, and seeks discard its state.
- FFmpeg playback handles release display dictionaries and attached-picture
  packets after codec setup, while import uses metadata-enabled handles. This
  reduces retention; it does not bypass FFmpeg's initial container/header parsing.
- Metadata ingestion has an explicit background actor, separate from playback and
  ImageIO decoding. Import cancellation reaches FFmpeg's probe/count loop and
  remains CancellationError instead of being reported as an unreadable file.

Regression coverage includes equal cold/warm PCM before and after seeking,
replacement with unchanged bytes/mtime, bounded LRU eviction, metadata retention
versus playback, cancellation, and a one-megabyte multi-page OpusTags packet.
Existing mono/stereo Opus waveform and seek tests cover buffer reuse. Native
ASan/UBSan stress now exercises both cold and cached opens, discarded metadata,
and mismatched-rate hints in addition to the existing error/ownership cases.

Follow-up validation: the full 125-test Mac suite passes on Apple silicon and
Intel/Rosetta (three optional external-model integrations skipped). The native
stress run passes 1,200 cold/cached cycles (2,400 opens) and 6,000 seeks under
ASan/UBSan; macOS leaks reports zero leaks. The universal Mac app passes strict
signature validation, and the shared code builds for iPad devices.
