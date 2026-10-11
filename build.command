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

echo "Building Cover Flow (release)…"
xcrun swift build -c release >> "$LOG" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "FAILED $rc" > "$STATUS"
  echo ""
  echo "Build failed. Details are in build.log:"
  grep -E "error:" "$LOG" | head -40
  exit $rc
fi

BIN_DIR=$(xcrun swift build -c release --show-bin-path)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CoverFlow" "$APP/Contents/MacOS/CoverFlow"

# App icon
if [ -f Resources/AppIcon-1024.png ]; then
  ICONSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
    d=$((s * 2))
    sips -z $d $d Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" >> "$LOG" 2>&1
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
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>Demo music and covers are generated on this Mac.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >> "$LOG" 2>&1

echo "OK" > "$STATUS"
echo "=== Build succeeded — $(date)" >> "$LOG"
echo "Built $APP. Launching…"
pkill -x CoverFlow 2>/dev/null; sleep 0.5
open "$APP"
