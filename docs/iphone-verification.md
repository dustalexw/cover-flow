# iPhone port and ready-to-run projects

The mobile version supports iOS/iPadOS 17+. Separate shared schemes are generated
for `iPhone/CoverFlow-iPhone.xcodeproj` (device family 1) and
`iPad/CoverFlow-iPad.xcodeproj` (device family 2). Each project preserves its own
signing team and bundle identifier when regenerated. The Mac target is unchanged.

Phone navigation uses five tabs, with Visualizer and Settings under More. The
mini-player stays above the tab bar. Now Playing controls wrap on small screens;
karaoke controls scroll independently of the full lyrics tab. Carousel padding,
centered snapping and a vertically scrollable stage keep short collections and
captions reachable in landscape. Wide tablets retain the sidebar layout.

`python3 scripts/package-ios-projects.py --output <folder>` creates a prepared
folder and ZIP containing both projects, shared Swift/Objective-C++ sources,
assets, privacy manifest, native ONNX Runtime and licenses. All project-relative
file references are checked inside the prepared folder. Open either project
without a dependency download, choose a signing team/device, and press Run.

Validation:

- iPhone and iPad device builds pass, plus an iPhone simulator build.
- Both copied projects build in Debug outside the repository, proving source and
  native-runtime paths remain valid after moving the prepared folder.
- Mobile core: 13 tests, zero failures, one optional user-supplied ONNX integration
  skipped. Includes Core ML waveform processing, spectrum round trips, import,
  navigation reachability, viewport bounds and centered snapping.
- Generator regression verifies separate device families, relative native paths,
  and preservation of per-project signing/bundle settings.
- iPhone 17e simulator: launch, five tabs, More → Visualizer → Collection, demo
  import, portrait artwork/captions, Now Playing controls and landscape centering
  checked in Device Hub.

Device builds used signing disabled for validation. Installation and testing on a
physical iPhone/iPad requires the user's signing team in Xcode; those physical
hardware and optional model-inference checks are not claimed here.
