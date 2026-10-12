#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VENDOR="$PWD/.build/vendor"
SOURCE="$VENDOR/taglib-2.3.2"
BUILD="$VENDOR/taglib-build-universal"
INSTALL="$VENDOR/taglib-install-universal"
ARCHIVE="$VENDOR/taglib-2.3.2.tar.gz"
mkdir -p "$VENDOR"
if [ ! -f "$ARCHIVE" ]; then
  curl -L --fail --retry 3 https://taglib.org/releases/taglib-2.3.2.tar.gz -o "$ARCHIVE"
fi
if [ "$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)" != "3ca2d8afaa7f1cf7f6ed10e511ebc368bfacd6dcaa3dbfa690b89e502e8963dc" ]; then
  echo "TagLib checksum mismatch. Remove $ARCHIVE and build again." >&2
  exit 1
fi
if [ ! -d "$SOURCE" ]; then tar -xzf "$ARCHIVE" -C "$VENDOR"; fi
if command -v cmake >/dev/null 2>&1; then
  CMAKE=$(command -v cmake)
else
  # build-visualizer.sh downloads this verified universal CMake first.
  CMAKE="$VENDOR/cmake-4.1.2-macos-universal/CMake.app/Contents/bin/cmake"
fi
"$CMAKE" -S "$SOURCE" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$INSTALL" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DBUILD_BINDINGS=OFF -DBUILD_EXAMPLES=OFF
"$CMAKE" --build "$BUILD" --parallel "$(sysctl -n hw.activecpu)"
"$CMAKE" --install "$BUILD"
bash scripts/verify-universal.sh "$INSTALL/lib/libtag.a"
