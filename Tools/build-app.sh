#!/bin/bash
# Builds Understudy.app and a zip ready for a GitHub release.
#
# Needs only Xcode Command Line Tools. Signing is ad-hoc, which is enough for
# the app to hold its own permissions and to run on Apple Silicon, but not
# enough for Gatekeeper to open it without the user clearing quarantine first.
# See the README for what that means for people downloading it.
#
#   ./Tools/build-app.sh

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Understudy.app"
VERSION="${1:-0.1.0}"

echo "Building release binary..."
swift build -c release --product Understudy

echo "Assembling $APP"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Understudy "$APP/Contents/MacOS/Understudy"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Understudy</string>
  <key>CFBundleIdentifier</key><string>com.understudy.app</string>
  <key>CFBundleName</key><string>Understudy</string>
  <key>CFBundleDisplayName</key><string>Understudy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <!-- Without both of these, macOS silently returns nothing from Bonjour
       instead of prompting for Local Network access. -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>Understudy finds your other Mac on this network to send the screen to it.</string>
  <key>NSBonjourServices</key>
  <array><string>_understudy._tcp</string></array>
</dict>
</plist>
PLIST

echo "Signing (ad-hoc)..."
codesign --force --sign - --identifier com.understudy.app --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"

echo "Zipping..."
ditto -c -k --keepParent "$APP" "build/Understudy-$VERSION.zip"

echo
echo "Built $APP"
echo "Release archive: build/Understudy-$VERSION.zip"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature"
