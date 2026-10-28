#!/bin/bash
# Builds the decoder-only FFmpeg used for formats macOS can't decode (Vorbis, Monkey's
# Audio, WavPack, WMA, DSD, Musepack, TTA, TAK, ...). LGPL only: no --enable-gpl or
# --enable-nonfree. Each architecture is built separately, then merged with lipo into
# shared libraries whose install names use @rpath, so the app bundles and loads them
# from Contents/Frameworks and anyone can replace them with their own build.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=7.1.2
VENDOR="$PWD/.build/vendor"
SOURCE="$VENDOR/ffmpeg-$VERSION"
ARCHIVE="$VENDOR/ffmpeg-$VERSION.tar.xz"
INSTALL="$VENDOR/ffmpeg-install-universal"
# Compiler and SDK changes invalidate binary caches, including a restored cache
# produced by another Xcode version on the same GitHub runner image.
IDENTITY=$({ shasum -a 256 "$0" scripts/verify-audio-runtime.sh | awk '{print $1}'; xcrun clang --version; xcrun --sdk macosx --show-sdk-version; } | shasum -a 256 | cut -c1-16)
STAMP=".complete-$IDENTITY"
mkdir -p "$VENDOR"
if [ -f "$INSTALL/$STAMP" ] && bash scripts/verify-audio-runtime.sh "$INSTALL"; then exit 0; fi
STAGING="$INSTALL.staging-$$"
BACKUP="$INSTALL.previous-$$"
cleanup() {
  if [ ! -d "$INSTALL" ] && [ -d "$BACKUP" ]; then mv "$BACKUP" "$INSTALL"; fi
  rm -rf "$STAGING"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -f "$ARCHIVE" ]; then
  curl -L --fail --retry 3 "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$ARCHIVE"
fi
if [ "$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)" != "089bc60fb59d6aecc5d994ff530fd0dcb3ee39aa55867849a2bbc4e555f9c304" ]; then
  echo "FFmpeg checksum mismatch. Remove $ARCHIVE and build again." >&2
  exit 1
fi
if [ ! -d "$SOURCE" ]; then tar -xJf "$ARCHIVE" -C "$VENDOR"; fi

DEMUXERS=ogg,ape,wv,asf,dsf,iff,matroska,mpc,mpc8,tta,tak,shorten,dts,w64
DECODERS=vorbis,opus,flac,speex,ape,wavpack,wmav1,wmav2,wmapro,wmalossless,wmavoice
DECODERS=$DECODERS,dsd_lsbf,dsd_lsbf_planar,dsd_msbf,dsd_msbf_planar,mpc7,mpc8,tta,tak,shorten
DECODERS=$DECODERS,dca,aac,ac3,eac3,mp1float,mp2float,mp3float,alac,truehd,mlp
DECODERS=$DECODERS,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_u8,pcm_alaw,pcm_mulaw
PARSERS=vorbis,opus,flac,dca,ac3,aac,mpegaudio,mlp,tak

JOBS=${COVERFLOW_BUILD_JOBS:-$(sysctl -n hw.activecpu 2>/dev/null || echo 4)}
case "$JOBS" in ''|*[!0-9]*|0) JOBS=4 ;; esac
if [ -z "${COVERFLOW_BUILD_JOBS:-}" ] && [ "$JOBS" -gt 8 ]; then JOBS=8; fi
SDK=$(xcrun --sdk macosx --show-sdk-path)
for ARCH in arm64 x86_64; do
  BUILD="$VENDOR/ffmpeg-build-$ARCH"
  rm -rf "$BUILD"
  mkdir -p "$BUILD"
  case $ARCH in arm64) FFARCH=aarch64 ;; x86_64) FFARCH=x86_64 ;; esac
  (
    cd "$BUILD"
    "$SOURCE/configure" \
      --prefix="$BUILD/install" --install-name-dir=@rpath \
      --enable-cross-compile --target-os=darwin --arch=$FFARCH \
      --cc="xcrun --sdk macosx clang -arch $ARCH" --sysroot="$SDK" \
      --extra-cflags="-arch $ARCH -mmacosx-version-min=14.0" \
      --extra-ldflags="-arch $ARCH -mmacosx-version-min=14.0" \
      --enable-shared --disable-static --enable-pic \
      --disable-programs --disable-doc --disable-network --disable-autodetect \
      --disable-everything --disable-avdevice --disable-avfilter --disable-swscale \
      --disable-x86asm \
      --enable-protocol=file --enable-demuxer=$DEMUXERS --enable-decoder=$DECODERS --enable-parser=$PARSERS
    make -j"$JOBS"
    make install
  )
done

rm -rf "$STAGING"
mkdir -p "$STAGING/lib"
cp -R "$VENDOR/ffmpeg-build-arm64/install/include" "$STAGING/"
for LIBRARY in "$VENDOR"/ffmpeg-build-arm64/install/lib/lib*.dylib; do
  NAME=$(basename "$LIBRARY")
  if [ -L "$LIBRARY" ]; then
    cp -P "$LIBRARY" "$STAGING/lib/$NAME"
  else
    xcrun lipo -create "$LIBRARY" "$VENDOR/ffmpeg-build-x86_64/install/lib/$NAME" -output "$STAGING/lib/$NAME"
    bash scripts/verify-universal.sh "$STAGING/lib/$NAME"
  fi
done
for ARCH in arm64 x86_64; do
  if ! grep -q '#define FFMPEG_LICENSE "LGPL' "$VENDOR/ffmpeg-build-$ARCH/config.h"; then
    echo "FFmpeg was not configured as LGPL." >&2
    exit 1
  fi
done
bash scripts/verify-audio-runtime.sh "$STAGING"
touch "$STAGING/$STAMP"
# Keep the working decoder intact until both slices and all dependencies pass.
if [ -d "$INSTALL" ]; then mv "$INSTALL" "$BACKUP"; fi
mv "$STAGING" "$INSTALL"
rm -rf "$BACKUP"
