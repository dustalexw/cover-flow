#!/bin/bash
# Build the portable Apple-silicon inference runtime. Model weights stay external.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/.build/vendor/karaoke-runtime"
ARCHIVE="$ROOT/.build/vendor/cpython-3.12.7+20241016-aarch64-apple-darwin-install_only.tar.gz"
CHECKSUM="4c18852bf9c1a11b56f21bcf0df1946f7e98ee43e9e4c0c5374b2b3765cf9508"
LOCK="$ROOT/Resources/Karaoke/runtime-lock.txt"
if [ -f "$OUT/.complete" ] && cmp -s "$LOCK" "$OUT/runtime-lock.txt"; then
  echo "Karaoke runtime is already prepared."
  exit 0
fi
mkdir -p "$ROOT/.build/vendor" "$OUT"
if [ ! -f "$ARCHIVE" ]; then
  curl -L --fail --retry 3 "https://github.com/astral-sh/python-build-standalone/releases/download/20241016/$(basename "$ARCHIVE")" -o "$ARCHIVE"
fi
echo "$CHECKSUM  $ARCHIVE" | shasum -a 256 -c -
tar -xzf "$ARCHIVE" -C "$OUT"
"$OUT/python/bin/python3" -m ensurepip
"$OUT/python/bin/python3" -m pip install --target "$OUT/site-packages" \
  --cache-dir "$ROOT/.build/pip-cache" --only-binary=:all: --no-deps --upgrade -r "$LOCK"
cp "$LOCK" "$OUT/runtime-lock.txt"
touch "$OUT/.complete"
echo "Karaoke runtime prepared."
