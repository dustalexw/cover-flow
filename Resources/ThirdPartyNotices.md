# MilkDrop visualizer

The optional karaoke processor uses the MIT-licensed Mel-Band RoFormer inference
implementation from ZFTurbo/Music-Source-Separation-Training at revision
5a3e16d1f7e6ac489bddbeb25069595527e170ce. Its source and license are included in
Resources/Karaoke. The minimal Slaney filter bank is adapted from librosa 0.11
under the ISC license, included there. Runtime package versions and their license
metadata are included in KaraokeRuntime. User-supplied Becruily model weights
and configurations are read locally and are not bundled or uploaded.

Cover Flow uses the unmodified **projectM 4.1.8** engine, copyright the projectM
Team, under the GNU LGPL 2.1 or later. Source and documentation:
https://github.com/projectM-visualizer/projectm/releases/tag/v4.1.8

The complete corresponding engine source, including its bundled dependencies,
is included in this app at `Contents/Resources/ThirdPartySources/projectm-4.1.8.tar.gz`.
License texts are in `Contents/Resources/Licenses`. The source archive's SHA-256
is `f72135e8b8e5fd807f908537255b41ac7ba4830309265e830cb756535487239e`.

Build on macOS using CMake and Xcode's C++ compiler:

```
tar -xzf projectm-4.1.8.tar.gz
cmake -S libprojectM-4.1.8 -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DENABLE_PLAYLIST=OFF \
  -DENABLE_SYSTEM_PROJECTM_EVAL=OFF -DENABLE_INSTALL=ON
cmake --build build --parallel
```

The engine is dynamically loaded from `Contents/Frameworks/libprojectM-4.dylib`.
You may replace it with a compatible projectM 4 C API library. Modification,
debugging, and reverse engineering of the app to debug changes to this LGPL
component are permitted. Re-sign the modified library and app for local use.
Cover Flow's bridge uses the original projectM 4.1.8 C API headers, also under
LGPL 2.1 or later. `scripts/build-visualizer.sh` contains the reproducible build.

projectM's bundled components include GLM (MIT or Happy Bunny), HLSL Parser
(MIT, Unknown Worlds Entertainment), projectM-eval (MIT, projectM Team), and
SOIL2 (MIT No Attribution) / stb image utilities (public domain). Their notices accompany the engine
source and the included license texts. The eight built-in `.milk` presets are
original Cover Flow presets.

# Artwork tags

Cover Flow uses unmodified **TagLib 2.3.2**, copyright Scott Wheeler and the
TagLib contributors, under the Mozilla Public License 1.1 option of its dual
MPL/LGPL license. It is statically linked into both app architectures. Complete
source, including the bundled utfcpp dependency (Boost Software License 1.0),
is included at `Contents/Resources/ThirdPartySources/taglib-2.3.2.tar.gz`.
License texts are in `Contents/Resources/Licenses`. Source and documentation:
https://taglib.org/ and https://github.com/taglib/taglib/releases/tag/v2.3.2

The source archive's SHA-256 is
`3ca2d8afaa7f1cf7f6ed10e511ebc368bfacd6dcaa3dbfa690b89e502e8963dc`.
`scripts/build-tags.sh` provides the reproducible universal static-library build:

```
cmake -S taglib-2.3.2 -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DBUILD_BINDINGS=OFF -DBUILD_EXAMPLES=OFF
cmake --build build --parallel
```

# Scene refinement (Stable Diffusion)

Optional scene refinement uses Apple's **ml-stable-diffusion 1.1.1** Swift
package, copyright Apple Inc., under the MIT License
(`Licenses/ml-stable-diffusion-MIT.txt`).
https://github.com/apple/ml-stable-diffusion/releases/tag/1.1.1

The bundled model in `Contents/Resources/StableDiffusion` is Apple's unmodified
6-bit Core ML conversion of **Stable Diffusion v1.5**
(`apple/coreml-stable-diffusion-v1-5-palettized`, `split_einsum_v2`), originally
released by Runway and Stability AI under the **CreativeML OpenRAIL-M** license,
which includes use-based restrictions that apply to anyone using the model:
https://huggingface.co/apple/coreml-stable-diffusion-v1-5-palettized
The model's built-in safety checker is enabled; flagged results are discarded
and the quilted scene is used instead.
