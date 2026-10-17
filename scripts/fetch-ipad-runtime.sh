#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHIVE="$PWD/.build/vendor/ipados/onnxruntime-1.24.2.zip"
CHECKSUM=f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54
if [ -f iPad/Vendor/.complete ] && [ "$(cat iPad/Vendor/.complete)" = "$CHECKSUM" ] && [ -d iPad/Vendor/onnxruntime.xcframework ]; then exit 0; fi
mkdir -p .build/vendor/ipados iPad/Vendor
if [ ! -f "$ARCHIVE" ]; then curl -L --fail --retry 3 https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip -o "$ARCHIVE"; fi
printf '%s  %s\n' "$CHECKSUM" "$ARCHIVE" | shasum -a 256 -c -
unzip -q -o "$ARCHIVE" -d iPad/Vendor
cp iPad/Vendor/LICENSE iPad/Resources/ONNX-Runtime-LICENSE.txt
printf '%s\n' "$CHECKSUM" > iPad/Vendor/.complete
