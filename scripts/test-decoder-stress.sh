#!/bin/bash
# Instrument the C ownership boundary; FFmpeg stays a replaceable shared dependency.
set -euo pipefail
cd "$(dirname "$0")/.."
RUNTIME="$PWD/.build/vendor/ffmpeg-install-universal"
bash scripts/verify-audio-runtime.sh "$RUNTIME"
mkdir -p .build/native-tests
xcrun --sdk macosx clang -std=c11 -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I Sources/CFFmpegAudio/include -I "$RUNTIME/include" \
  Sources/CFFmpegAudio/CFAudioFile.c Tests/Native/DecoderStress.c \
  -L "$RUNTIME/lib" -Wl,-rpath,"$RUNTIME/lib" \
  -lavformat -lavcodec -lswresample -lavutil \
  -o .build/native-tests/decoder-stress
ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  .build/native-tests/decoder-stress "$PWD/Tests/CoverFlowTests/Fixtures"
