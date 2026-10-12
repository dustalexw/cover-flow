#!/bin/bash
set -euo pipefail

for BINARY in "$@"; do
  ARCHS=$(xcrun lipo -archs "$BINARY")
  for REQUIRED_ARCH in arm64 x86_64; do
    case " $ARCHS " in
      *" $REQUIRED_ARCH "*) ;;
      *) echo "Universal binary is missing $REQUIRED_ARCH: $BINARY" >&2; exit 1 ;;
    esac
  done
done
