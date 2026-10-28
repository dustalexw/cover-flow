#!/bin/bash
# Validate the replaceable macOS decoder libraries before trusting a build cache.
set -euo pipefail
RUNTIME="${1:?Pass the FFmpeg install directory}"
for HEADER in libavcodec/avcodec.h libavformat/avformat.h libavutil/avutil.h libswresample/swresample.h; do
  test -s "$RUNTIME/include/$HEADER" || { echo "Missing FFmpeg header: $HEADER" >&2; exit 1; }
done
for NAME in libavcodec.61.dylib libavformat.61.dylib libavutil.59.dylib libswresample.5.dylib; do
  LIBRARY="$RUNTIME/lib/$NAME"
  test -s "$LIBRARY" || { echo "Missing FFmpeg library: $NAME" >&2; exit 1; }
  bash "$(dirname "$0")/verify-universal.sh" "$LIBRARY"
  for ARCH in arm64 x86_64; do
    PLATFORM=$(xcrun vtool -arch "$ARCH" -show-build "$LIBRARY" | awk '/platform / {print $2}')
    test "$PLATFORM" = MACOS || { echo "$NAME ($ARCH) is not a macOS library." >&2; exit 1; }
  done
  INSTALL_NAME=$(otool -D "$LIBRARY" | tail -1)
  test "$INSTALL_NAME" = "@rpath/$NAME" || { echo "Unexpected install name: $INSTALL_NAME" >&2; exit 1; }
  while IFS= read -r DEPENDENCY; do
    case "$DEPENDENCY" in @rpath/*|/usr/lib/*|/System/Library/*) ;;
      *) echo "Non-portable decoder dependency: $DEPENDENCY" >&2; exit 1 ;;
    esac
  done < <(otool -L "$LIBRARY" | awk '/^\t/ { print $1 }')
done
