#!/bin/bash
# Builds Encore.app and a zip ready for a GitHub release.
#
# Needs only Xcode Command Line Tools. Signing is ad-hoc, which is enough for
# the app to hold its own permissions and to run on Apple Silicon, but not
# enough for Gatekeeper to open it without the user clearing quarantine first.
# See the README for what that means for people downloading it.
#
#   ./Tools/build-app.sh

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Encore.app"
VERSION="${1:-0.1.0}"

echo "Building release binary..."
swift build -c release --product Encore

echo "Assembling $APP"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Encore "$APP/Contents/MacOS/Encore"

# Built from Tools/icon.png rather than a committed .icns, so replacing that one
# file is all it takes to change the icon. Tools/icon.svg is the artwork it came
# from; re-render it with:
#
#   swift Tools/render-icon.swift
ICON_KEY=""
if [ -f Tools/icon.png ]; then
    echo "Building the icon..."
    ICONSET="build/Encore.iconset"
    mkdir -p "$ICONSET"
    for SIZE in 16 32 128 256 512; do
        sips -z $SIZE $SIZE Tools/icon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
        sips -z $((SIZE * 2)) $((SIZE * 2)) Tools/icon.png \
             --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Encore.icns"
    rm -rf "$ICONSET"
    ICON_KEY="  <key>CFBundleIconFile</key><string>Encore</string>"
else
    echo "No Tools/icon.png, building without an icon."
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Encore</string>
  <key>CFBundleIdentifier</key><string>io.github.chachasmooth.encore</string>
  <key>CFBundleName</key><string>Encore</string>
  <key>CFBundleDisplayName</key><string>Encore</string>
$ICON_KEY
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <!-- Without both of these, macOS silently returns nothing from Bonjour
       instead of prompting for Local Network access. -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>Encore finds your other Mac on this network to send the screen to it.</string>
  <key>NSBonjourServices</key>
  <array><string>_encore._tcp</string></array>
</dict>
</plist>
PLIST

echo "Signing (ad-hoc)..."
codesign --force --sign - --identifier io.github.chachasmooth.encore --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"

echo "Zipping..."
ditto -c -k --keepParent "$APP" "build/Encore.zip"

echo
echo "Built $APP"
echo "Release archive: build/Encore.zip"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature"
