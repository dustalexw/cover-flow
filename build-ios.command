#!/bin/bash
# iPhone entry point. The iPad project remains available through build-ipad.command.
set -euo pipefail
cd "$(dirname "$0")"
bash scripts/fetch-ipad-runtime.sh
python3 scripts/make-ipad-project.py
MODE="${1:---device}"
if [ "$MODE" = --project ]; then
  open -a Xcode "$PWD/iPhone/CoverFlow-iPhone.xcodeproj"
  exit 0
fi
SDK=iphoneos
DESTINATION="generic/platform=iOS"
OUT="$PWD/iPhone/build"
if [ "$MODE" = --simulator ]; then
  SDK=iphonesimulator
  DESTINATION="generic/platform=iOS Simulator"
  OUT="$PWD/iPhone/build-simulator"
elif [ "$MODE" != --device ]; then
  echo "Usage: ./build-ios.command [--device | --simulator | --project]"
  exit 2
fi
EXTRA=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
if [ "${COVERFLOW_COMPILER_SANDBOX_WORKAROUND:-0}" = 1 ]; then EXTRA+=('OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox'); fi
xcodebuild -project iPhone/CoverFlow-iPhone.xcodeproj -scheme CoverFlowiPhone \
  -configuration Release -sdk "$SDK" -destination "$DESTINATION" \
  -derivedDataPath "$OUT" "${EXTRA[@]}" build
echo "Built: $OUT/Build/Products/Release-$SDK/Cover Flow.app"
echo "For device installation, open the project, select your signing team and iPhone, and Run."
