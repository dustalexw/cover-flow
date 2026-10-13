#!/bin/bash
# Builds "Cover Flow.app" next to this script and launches it.
# Double-click in Finder, or run ./build.command in Terminal.
cd "$(dirname "$0")" || exit 1

LOG="build.log"
STATUS="build.status"
APP="Cover Flow.app"

echo "building" > "$STATUS"
echo "=== Cover Flow build — $(date)" > "$LOG"
sw_vers >> "$LOG" 2>&1
xcrun swift --version >> "$LOG" 2>&1

echo "Building Cover Flow (universal release)…"
bash scripts/build-visualizer.sh >> "$LOG" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "FAILED $rc" > "$STATUS"
  echo "Visualizer build failed. Details are in build.log."
  exit $rc
fi
# Stable Diffusion scene refinement model. Set COVERFLOW_SKIP_SD=1 to build
# without it; the app then keeps using quilted scenes only.
if [ "${COVERFLOW_SKIP_SD:-0}" != "1" ]; then
  echo "Preparing Stable Diffusion model (first build downloads about 1.6 GB)…"
  bash scripts/fetch-sd-model.sh >> "$LOG" 2>&1 || {
    echo "FAILED stable diffusion" > "$STATUS"
    echo "Stable Diffusion model download failed. Details are in build.log, or build with COVERFLOW_SKIP_SD=1."
    exit 1
  }
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
bash scripts/build-tags.sh >> "$LOG" 2>&1 || { echo "Tag writer build failed. Details are in build.log."; exit 1; }
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
SWIFT_BUILD_ARGS=(-c release --arch arm64 --arch x86_64 -debug-info-format "${DEBUG_INFO_FORMAT:-dwarf}" \
  --scratch-path "${SWIFT_SCRATCH_PATH:-$PWD/.build}" --disable-sandbox --cache-path "$PWD/.build/swift-cache")
xcrun swift build "${SWIFT_BUILD_ARGS[@]}" \
  -Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH" >> "$LOG" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "FAILED $rc" > "$STATUS"
  echo ""
  echo "Build failed. Details are in build.log:"
  grep -E "error:" "$LOG" | head -40
  exit $rc
fi

BIN_DIR=$(xcrun swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path) || exit 1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ThirdPartySources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/CoverFlow" "$APP/Contents/MacOS/CoverFlow"
cp -R "$BIN_DIR/CoverFlow_CoverFlow.bundle" "$APP/Contents/Resources/"
cp .build/vendor/projectm-install-universal/lib/libprojectM-4.4.1.8.dylib "$APP/Contents/Frameworks/libprojectM-4.dylib"
install_name_tool -id @rpath/libprojectM-4.dylib "$APP/Contents/Frameworks/libprojectM-4.dylib"
cp -R Resources/Licenses "$APP/Contents/Resources/"
cp .build/vendor/projectm.tar.gz "$APP/Contents/Resources/ThirdPartySources/projectm-4.1.8.tar.gz"
cp .build/vendor/taglib-2.3.2.tar.gz "$APP/Contents/Resources/ThirdPartySources/"
cp Resources/ThirdPartyNotices.md "$APP/Contents/Resources/"
if [ "${COVERFLOW_SKIP_SD:-0}" != "1" ]; then
  ditto .build/vendor/stable-diffusion-model "$APP/Contents/Resources/StableDiffusion"
  rm -f "$APP/Contents/Resources/StableDiffusion/.complete"
fi

# App icon
if [ -f Resources/AppIcon-1024.png ]; then
  ICONSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
    d=$((s * 2))
    sips -z $d $d Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  if ! iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" >> "$LOG" 2>&1; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" || exit 1
  fi
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Cover Flow</string>
  <key>CFBundleDisplayName</key><string>Cover Flow</string>
  <key>CFBundleIdentifier</key><string>app.coverflow.player</string>
  <key>CFBundleExecutable</key><string>CoverFlow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.4.0</string>
  <key>CFBundleVersion</key><string>18</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>Demo music and covers are generated on this Mac.</string>
</dict>
</plist>
PLIST

# Both the app and the dynamically loaded visualizer must support both CPUs.
if ! bash scripts/verify-universal.sh "$APP/Contents/MacOS/CoverFlow" \
  "$APP/Contents/Frameworks/libprojectM-4.dylib" >> "$LOG" 2>&1; then
  echo "FAILED architecture check" > "$STATUS"
  echo "Universal build is missing an architecture. Details are in build.log."
  exit 1
fi

codesign --force --sign - "$APP/Contents/Frameworks/libprojectM-4.dylib" >> "$LOG" 2>&1
codesign --force --sign - "$APP" >> "$LOG" 2>&1
codesign --verify --deep --strict "$APP" >> "$LOG" 2>&1 || exit 1

echo "OK" > "$STATUS"
echo "=== Build succeeded — $(date)" >> "$LOG"
echo "Built $APP. Launching…"
if [ "${1:-}" = "--no-launch" ]; then exit 0; fi
pkill -x CoverFlow 2>/dev/null; sleep 0.5
open "$APP"
