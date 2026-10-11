#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VENDOR="$PWD/.build/vendor"
SOURCE="$VENDOR/libprojectM-4.1.8"
mkdir -p "$VENDOR"

download() {
  local url="$1" destination="$2" checksum="$3"
  if [ ! -f "$destination" ]; then curl -L --fail --retry 3 "$url" -o "$destination"; fi
  if [ "$(shasum -a 256 "$destination" | cut -d ' ' -f 1)" != "$checksum" ]; then
    echo "Dependency checksum mismatch: $destination. Remove it and build again." >&2
    exit 1
  fi
}

download https://github.com/projectM-visualizer/projectm/releases/download/v4.1.8/libprojectM-4.1.8.tar.gz \
  "$VENDOR/projectm.tar.gz" f72135e8b8e5fd807f908537255b41ac7ba4830309265e830cb756535487239e
if [ ! -d "$SOURCE" ]; then tar -xzf "$VENDOR/projectm.tar.gz" -C "$VENDOR"; fi

if command -v cmake >/dev/null 2>&1; then
  CMAKE=$(command -v cmake)
else
  download https://github.com/Kitware/CMake/releases/download/v4.1.2/cmake-4.1.2-macos-universal.tar.gz \
    "$VENDOR/cmake.tar.gz" 3be85f5b999e327b1ac7d804cbc9acd767059e9f603c42ec2765f6ab68fbd367
  if [ ! -d "$VENDOR/cmake-4.1.2-macos-universal" ]; then tar -xzf "$VENDOR/cmake.tar.gz" -C "$VENDOR"; fi
  CMAKE="$VENDOR/cmake-4.1.2-macos-universal/CMake.app/Contents/bin/cmake"
fi

"$CMAKE" -S "$SOURCE" -B "$VENDOR/projectm-build" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$VENDOR/projectm-install" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
  -DENABLE_PLAYLIST=OFF -DENABLE_SYSTEM_PROJECTM_EVAL=OFF -DENABLE_INSTALL=ON
"$CMAKE" --build "$VENDOR/projectm-build" --parallel "$(sysctl -n hw.activecpu)"
"$CMAKE" --install "$VENDOR/projectm-build"
