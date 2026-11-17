# iPhone Duo verification

Checked in CI on this branch (`.github/workflows/ipados.yml`, `.github/workflows/duo-preview.yml`):

- **iOS 27.2 SDK (Xcode 27.2, `xcode-27` runner):** iPhone simulator, iPhone device and iPad
  simulator builds compile with `COVERFLOW_DUO_SDK`, i.e. with `reservedRegions(kind:)` and
  `onHingeChange` (guarded by `#available(iOS 27.1, *)`).
- **Xcode 16.4 (`macos-15`):** FFmpeg 7.1.2 and TagLib 2.3.2 build for iOS device and
  simulator; both projects link them; `cf_audio_open` and `cf_artwork_write` are present in
  the iPhone binary; iPad and iPhone device and simulator builds pass; 19 core tests pass,
  including six fold-geometry tests (book, tabletop, flat, off-view and edge folds, hinge).
- **Mac build:** unchanged behavior after moving the scene generator into
  `AlbumSceneGenerator.swift`.
- **iPhone Duo simulator (iOS 27.2), outer display:** Collection, album sheet and Album View
  render with iOS 27's vertical bar; Album View keeps the transport on screen.
- **Expanded shell (iPad mini simulator, same code as the inner display):** Cover Flow with
  the album panel beside it, Immersive Album View with a generated scene, Karaoke with
  lyrics; no crashes across launches.

Not verified here: the inner display itself and book/tabletop poses (the simulator can't be
unfolded from the command line; use Device Hub in Xcode 27.1+), physical hardware, and
playback of the extended formats on a device.
