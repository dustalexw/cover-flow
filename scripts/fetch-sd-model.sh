#!/bin/bash
# Downloads Apple's 6-bit Core ML Stable Diffusion 1.5 model (Neural Engine
# variant) used to refine album scenes, verifies it, and unpacks it to
# .build/vendor/stable-diffusion-model. build.command copies that folder into
# the app. The archive is about 1.6 GB and is only downloaded once.
set -euo pipefail
cd "$(dirname "$0")/.."
VENDOR="$PWD/.build/vendor"
NAME="coreml-stable-diffusion-v1-5-palettized_split_einsum_v2_compiled"
URL="https://huggingface.co/apple/coreml-stable-diffusion-v1-5-palettized/resolve/main/$NAME.zip"
CHECKSUM="49a6ac1f62e12a2b3e426730d686fa466e30cba11c03b85305775714fb9814ec"
ZIP="$VENDOR/$NAME.zip"
OUT="$VENDOR/stable-diffusion-model"
UNPACK="$VENDOR/stable-diffusion-unpack"
mkdir -p "$VENDOR"

if [ -f "$OUT/.complete" ]; then
  echo "Stable Diffusion model already prepared."
  exit 0
fi

if [ ! -f "$ZIP" ]; then
  echo "Downloading Stable Diffusion model (about 1.6 GB)…"
  # -C - resumes an interrupted download.
  curl -L --fail --retry 3 -C - "$URL" -o "$ZIP.part"
  mv "$ZIP.part" "$ZIP"
fi
if [ "$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)" != "$CHECKSUM" ]; then
  echo "Stable Diffusion model checksum mismatch: $ZIP. Remove it and build again." >&2
  exit 1
fi

rm -rf "$OUT" "$UNPACK"
mkdir -p "$UNPACK"
ditto -x -k "$ZIP" "$UNPACK"
VOCAB=$(find "$UNPACK" -name vocab.json -not -path "*/__MACOSX/*" -print -quit)
if [ -z "$VOCAB" ]; then
  echo "The Stable Diffusion archive has no vocab.json." >&2
  exit 1
fi
ROOT=$(dirname "$VOCAB")
for required in TextEncoder.mlmodelc VAEEncoder.mlmodelc VAEDecoder.mlmodelc merges.txt; do
  if [ ! -e "$ROOT/$required" ]; then
    echo "The Stable Diffusion archive is missing $required." >&2
    exit 1
  fi
done
if [ ! -e "$ROOT/Unet.mlmodelc" ] && [ ! -e "$ROOT/UnetChunk1.mlmodelc" ]; then
  echo "The Stable Diffusion archive has no Unet model." >&2
  exit 1
fi
mv "$ROOT" "$OUT"
rm -rf "$UNPACK"
touch "$OUT/.complete"
echo "Stable Diffusion model ready: $(du -sh "$OUT" | cut -f 1)"
