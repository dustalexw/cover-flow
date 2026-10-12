# MilkDrop visualizer

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
