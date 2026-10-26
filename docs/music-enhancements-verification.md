# Music visuals and downloads — October 26, 2026

Local versions: macOS 1.7.0 and iPadOS 1.1.0 (2).

The default visualizer now uses native Metal instead of OpenGL/projectM. Four
original shaders render Pulse, Aurora, Spectrum and Nebula styles, with a
60/30 fps control, Retina backing resolution, highlight mapping and analytic
antialiasing. Existing MilkDrop presets remain available through settings.
The stereo 2048-point analyser combines channel power after the FFT, uses
64 logarithmic bands and time-based attack/release, and retains audio between
render callbacks. A bounded visual gain exposes quiet detail without changing
playback volume. The player requests 512-frame visualizer tap buffers.

The macOS suite ran 93 tests with zero failures. Six checks initially skipped
because the sandbox could not access graphics/audio devices. Separate runs
outside the sandbox then passed the Metal rendering check and all six existing
playback checks, including the initially skipped audio checks. All four shaders
compiled on the GPU and rendered distinct quiet/active outputs. Captures were
inspected; the circular styles' wrap seam was corrected and rechecked. After
softening the immersive background texture, all 14 scene/appearance checks passed.

A separate preview app used a generated test collection and its own data folder.
UI checks verified Metal settings, online lyric search/preview/save, synced lyric
loading, MusicBrainz search, cover preview/application, and immersive scene
controls/composition. The original user collection was not changed. Live service
smoke tests returned LRCLIB matches, MusicBrainz release groups and a cover image.
Fixture tests cover matching, request encoding, service errors, response limits,
local lyric imports and preservation of the original audio file.

Immersive scenes use the foreground cover's actual rectangle, cache separately
from album-panel scenes, cancel stale work, and keep texture restrained around
the unchanged foreground cover. The existing optional Stable Diffusion extension
path is reused. AI refinement was not newly benchmarked in this change.

Both generic iPad device and simulator release builds compile. Physical iPad
playback, performance and Files-provider interactions still require device checks.
Frame rate depends on GPU and window size. Lyric timing, artwork availability
and image resolution depend on the selected provider record. On iPad, artwork
focus retains its existing artwork backdrop; the generated immersive extension
is currently a Mac feature.
