#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash scripts/fetch-ipad-runtime.sh
python3 scripts/make-ipad-project.py
MODE="${1:---device}"
if [ "$MODE" = "--project" ]; then
  open -a Xcode "$PWD/iPad/CoverFlow-iPad.xcodeproj"
  exit 0
fi
SDK=iphoneos
DESTINATION="generic/platform=iOS"
OUT="$PWD/iPad/build"
if [ "$MODE" = "--simulator" ]; then
  SDK=iphonesimulator
  DESTINATION="generic/platform=iOS Simulator"
  OUT="$PWD/iPad/build-simulator"
elif [ "$MODE" != "--device" ]; then
  echo "Usage: ./build-ipad.command [--device | --simulator | --project]"
  exit 2
fi
EXTRA=()
# Swift's compiler plugin sandbox cannot nest inside some CI/agent sandboxes.
# Ordinary Xcode builds keep the compiler's default behavior.
if [ "${COVERFLOW_COMPILER_SANDBOX_WORKAROUND:-0}" = 1 ]; then EXTRA+=('OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox'); fi
xcodebuild -project iPad/CoverFlow-iPad.xcodeproj -scheme CoverFlowiPad \
  -configuration Release -sdk "$SDK" -destination "$DESTINATION" \
  -derivedDataPath "$OUT" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "${EXTRA[@]}" build
echo "Built: $OUT/Build/Products/Release-$SDK/Cover Flow.app"
echo "For device installation, open the Xcode project, select your team in Signing & Capabilities, choose your iPad, and Run."
