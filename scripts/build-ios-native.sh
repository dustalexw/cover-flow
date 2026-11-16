#!/bin/bash
# Builds the Mac app's audio libraries for iPhone and iPad, so the mobile projects play
# the same formats and embed artwork the same way:
#
#   * FFmpeg 7.1.2, decoder-only and LGPL-only (no --enable-gpl or --enable-nonfree),
#     with the same demuxers and decoders as scripts/build-ffmpeg.sh.
#   * TagLib 2.3.2, for embedding replaced covers in imported audio files.
#
# Each library is built for iOS devices (arm64) and the iOS Simulator (arm64 and
# x86_64) and packaged as a static XCFramework in iPad/Vendor, with headers beside it.
# scripts/make-ipad-project.py adds whatever was prepared; if a library is missing the
# app still builds and simply keeps the smaller format list. The libraries are
# statically linked, so anyone distributing the app must meet the LGPL's relinking
# terms (for example by offering the app's object files); personal builds installed
# with your own developer account are unaffected.
#
# Usage: scripts/build-ios-native.sh [ffmpeg] [taglib]   (default: both)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SOURCES="$ROOT/.build/vendor"
WORK="$ROOT/.build/vendor/ios-native"
OUT="$ROOT/iPad/Vendor"
MIN_IOS=17.0
FFMPEG_VERSION=7.1.2
FFMPEG_SHA=089bc60fb59d6aecc5d994ff530fd0dcb3ee39aa55867849a2bbc4e555f9c304
TAGLIB_VERSION=2.3.2
TAGLIB_SHA=3ca2d8afaa7f1cf7f6ed10e511ebc368bfacd6dcaa3dbfa690b89e502e8963dc

WANT="${*:-ffmpeg taglib}"
mkdir -p "$SOURCES" "$WORK" "$OUT"
JOBS=${COVERFLOW_BUILD_JOBS:-$(sysctl -n hw.activecpu 2>/dev/null || echo 4)}
case "$JOBS" in ''|*[!0-9]*|0) JOBS=4 ;; esac

# Compiler, SDK and script changes invalidate prepared libraries.
IDENTITY=$({ shasum -a 256 "$0" | awk '{print $1}'; xcrun clang --version; xcrun --sdk iphoneos --show-sdk-version; xcrun --sdk iphonesimulator --show-sdk-version; } | shasum -a 256 | cut -c1-16)

# slice name, SDK, clang target triples
SLICES=("ios iphoneos arm64-apple-ios$MIN_IOS" "simulator iphonesimulator arm64-apple-ios$MIN_IOS-simulator x86_64-apple-ios$MIN_IOS-simulator")

fetch() { # url archive sha
  if [ ! -f "$2" ]; then curl -L --fail --retry 3 "$1" -o "$2.part" && mv "$2.part" "$2"; fi
  if [ "$(shasum -a 256 "$2" | cut -d ' ' -f 1)" != "$3" ]; then
    echo "Checksum mismatch for $2. Remove it and build again." >&2
    return 1
  fi
}

build_ffmpeg() {
  local name=CoverFlowFFmpeg
  if [ -f "$OUT/.$name-$IDENTITY" ] && [ -d "$OUT/$name.xcframework" ] && [ -d "$OUT/ffmpeg-include" ]; then
    echo "FFmpeg for iOS is up to date."
    return 0
  fi
  local archive="$SOURCES/ffmpeg-$FFMPEG_VERSION.tar.xz" source="$SOURCES/ffmpeg-$FFMPEG_VERSION"
  fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$archive" "$FFMPEG_SHA"
  if [ ! -d "$source" ]; then tar -xJf "$archive" -C "$SOURCES"; fi

  local demuxers=ogg,ape,wv,asf,dsf,iff,matroska,mpc,mpc8,tta,tak,shorten,dts,w64
  local decoders=vorbis,opus,flac,speex,ape,wavpack,wmav1,wmav2,wmapro,wmalossless,wmavoice
  decoders=$decoders,dsd_lsbf,dsd_lsbf_planar,dsd_msbf,dsd_msbf_planar,mpc7,mpc8,tta,tak,shorten
  decoders=$decoders,dca,aac,ac3,eac3,mp1float,mp2float,mp3float,alac,truehd,mlp
  decoders=$decoders,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_u8,pcm_alaw,pcm_mulaw
  local parsers=vorbis,opus,flac,dca,ac3,aac,mpegaudio,mlp,tak

  local libraries=() slice sdk triples triple arch ffarch build sysroot merged
  for entry in "${SLICES[@]}"; do
    read -r slice sdk triples <<<"$entry"
    sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
    local parts=()
    for triple in $triples; do
      arch=${triple%%-*}
      case $arch in arm64) ffarch=aarch64 ;; x86_64) ffarch=x86_64 ;; esac
      build="$WORK/ffmpeg-$slice-$arch"
      rm -rf "$build"; mkdir -p "$build"
      (
        cd "$build"
        "$source/configure" \
          --prefix="$build/install" \
          --enable-cross-compile --target-os=darwin --arch=$ffarch \
          --cc="xcrun --sdk $sdk clang -target $triple" --sysroot="$sysroot" \
          --extra-cflags="-target $triple" --extra-ldflags="-target $triple" \
          --enable-static --disable-shared --enable-pic --disable-debug \
          --disable-programs --disable-doc --disable-network --disable-autodetect \
          --disable-everything --disable-avdevice --disable-avfilter --disable-swscale \
          --disable-x86asm \
          --enable-protocol=file --enable-demuxer=$demuxers --enable-decoder=$decoders --enable-parser=$parsers \
          > configure.log 2>&1 || { tail -40 configure.log; tail -40 ffbuild/config.log 2>/dev/null; exit 1; }
        if ! grep -q '#define FFMPEG_LICENSE "LGPL' config.h; then
          echo "FFmpeg was not configured as LGPL." >&2; exit 1
        fi
        make -j"$JOBS" >/dev/null
        make install >/dev/null
      )
      merged="$build/libffmpeg.a"
      xcrun libtool -static -o "$merged" "$build"/install/lib/libavformat.a "$build"/install/lib/libavcodec.a \
        "$build"/install/lib/libswresample.a "$build"/install/lib/libavutil.a 2>/dev/null
      parts+=("$merged")
    done
    mkdir -p "$WORK/ffmpeg-$slice"
    xcrun lipo -create "${parts[@]}" -output "$WORK/ffmpeg-$slice/libffmpeg.a"
    libraries+=(-library "$WORK/ffmpeg-$slice/libffmpeg.a")
  done
  rm -rf "$OUT/$name.xcframework" "$OUT/ffmpeg-include" "$OUT"/.$name-*
  xcodebuild -create-xcframework "${libraries[@]}" -output "$OUT/$name.xcframework" >/dev/null
  cp -R "$WORK/ffmpeg-ios-arm64/install/include" "$OUT/ffmpeg-include"
  cp "$ROOT/Resources/Licenses/FFmpeg-LGPL-2.1.txt" "$OUT/ffmpeg-include/LICENSE.txt"
  touch "$OUT/.$name-$IDENTITY"
  echo "Built $OUT/$name.xcframework"
}

build_taglib() {
  local name=CoverFlowTagLib
  if [ -f "$OUT/.$name-$IDENTITY" ] && [ -d "$OUT/$name.xcframework" ] && [ -d "$OUT/taglib-include" ]; then
    echo "TagLib for iOS is up to date."
    return 0
  fi
  local cmake
  if command -v cmake >/dev/null 2>&1; then
    cmake=$(command -v cmake)
  elif [ -x "$SOURCES/cmake-4.1.2-macos-universal/CMake.app/Contents/bin/cmake" ]; then
    cmake="$SOURCES/cmake-4.1.2-macos-universal/CMake.app/Contents/bin/cmake"
  else
    echo "CMake is needed to build TagLib for iOS (install it, or run ./build.command once)." >&2
    return 1
  fi
  local archive="$SOURCES/taglib-$TAGLIB_VERSION.tar.gz" source="$SOURCES/taglib-$TAGLIB_VERSION"
  fetch "https://taglib.org/releases/taglib-$TAGLIB_VERSION.tar.gz" "$archive" "$TAGLIB_SHA"
  if [ ! -d "$source" ]; then tar -xzf "$archive" -C "$SOURCES"; fi
  local libraries=() slice sdk triples archs build
  for entry in "${SLICES[@]}"; do
    read -r slice sdk triples <<<"$entry"
    archs=$(for triple in $triples; do printf '%s;' "${triple%%-*}"; done)
    archs=${archs%;}
    build="$WORK/taglib-$slice"
    rm -rf "$build"
    "$cmake" -S "$source" -B "$build/build" \
      -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES="$archs" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$build/install" \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DBUILD_BINDINGS=OFF -DBUILD_EXAMPLES=OFF \
      >"$WORK/taglib-$slice.log" 2>&1 || { tail -40 "$WORK/taglib-$slice.log"; return 1; }
    "$cmake" --build "$build/build" --parallel "$JOBS" >>"$WORK/taglib-$slice.log" 2>&1 \
      || { tail -40 "$WORK/taglib-$slice.log"; return 1; }
    "$cmake" --install "$build/build" >>"$WORK/taglib-$slice.log" 2>&1
    libraries+=(-library "$build/install/lib/libtag.a")
  done
  rm -rf "$OUT/$name.xcframework" "$OUT/taglib-include" "$OUT"/.$name-*
  xcodebuild -create-xcframework "${libraries[@]}" -output "$OUT/$name.xcframework" >/dev/null
  cp -R "$WORK/taglib-ios/install/include" "$OUT/taglib-include"
  touch "$OUT/.$name-$IDENTITY"
  echo "Built $OUT/$name.xcframework"
}

status=0
for library in $WANT; do
  case $library in
    ffmpeg) build_ffmpeg || { echo "FFmpeg for iOS was not built; the app keeps its smaller format list." >&2; status=1; } ;;
    taglib) build_taglib || { echo "TagLib for iOS was not built; covers are saved to the collection only." >&2; status=1; } ;;
    *) echo "Unknown library: $library" >&2; exit 2 ;;
  esac
done
exit $status
