# Karaoke verification — October 14, 2026

The local 1.5.0 build uses the user's Becruily Deux checkpoint and matching YAML.
Model weights remain outside the app and all processing is local. The included
Apple-silicon Python runtime provides PyTorch 2.13 and pinned dependencies.

The supplied checkpoint loads with all **1,188 state keys matching**. Its SHA-256
is `10255c02295bf3e3865d4ee50ff752d7b19b124ed5fd93b147babc4333eda3aa`.
Real model inference generates two finite stereo stems at 44.1 kHz. A two-second
tone sample produces exactly 88,200 frames in each output, with instrumental RMS
0.07815 and vocal RMS 0.00000115. This is a model-execution check, not a claim of
measured vocal-separation quality on songs.

The packaged processor is also exercised through the actual Swift process bridge:
48 kHz audio with spaces and Unicode in its filename is decoded to 44.1 kHz,
processed by the supplied checkpoint, and checked for stereo channel count,
exact frame count, matching model digest and unchanged original file bytes.

Twelve karaoke Swift checks pass, covering discovery, missing models, changed-source
cache keys, resampling, cancellation during preparation and in a running worker,
valid and incomplete caches, matching stem lengths and packaged inference.
The shortcut regression also checks physical Space, mode/preparation keys, Caps Lock,
ignored menu modifiers, unrelated keys and recognition of repeats for consumption.
Build 21 moves the mode selector and preparation onto the lyric playback row, with
visible shortcut badges. The window monitor only handles its own active window,
excludes editable text and dialogs, and consumes repeats without firing again.
Build 22 adds paired Karaoke and Vocals Only icons beside Lyrics in the main player,
automatic preparation, an inline progress bar/percentage, and a progress popover
with cancellation. Cached-mode requests switch immediately. A new test runs the
supplied model through the complete store workflow, checks that a newer Vocals
request replaces an earlier Karaoke request, and validates the resulting saved
stems and unchanged source. Another verifies that Original, track changes and
cancellation clear pending automatic switches.
The existing 56 Swift checks were also run; five audio-component-dependent checks
are skipped in this environment. Three Python checks pass for overlap-add at short
and long edge lengths, safe YAML parsing and rejected stem-order mismatches.
The minimal filter bank exactly matches librosa 0.11 for the supplied configuration.

Release verification reran the full suite: 68 Swift checks, five environment skips,
zero failures, plus all three Python checks. Direct Python test invocations use
`-B` so running tests cannot add bytecode files to the signed app; the production
process bridge already sets `PYTHONDONTWRITEBYTECODE=1`. CI verifies signing again
after its processor tests and preserves already-published downloads and checksums.

The universal native player and visualizer retain their architecture checks. The
new processing runtime targets Apple silicon. Deep signing verification passes;
the Stable Diffusion scene assets from the existing signed build are retained.
Metal acceleration and live desktop/audio interaction are not available for
verification in this sandbox. CPU inference and file-processing paths are verified.

Desktop follow-up: in View → Karaoke, focus a lyric or mode button and press Space
to pause/resume. Press 1/2/3 to switch sources after preparation, or P to prepare an
uncached track. Hold Space to confirm a single change. Open Import LRC or Choose
model and verify typing works normally. Close/reopen Karaoke and verify shortcuts
remain local to that window. Confirm controls fit at its 540-point minimum width.
In the standard window, click either source icon on an unprepared track, check
progress and cancel details, then let it finish and confirm the requested source
plays. Click the selected icon again for original audio. Check the 720-point main
window minimum width, the compact bar and light/dark appearances.
