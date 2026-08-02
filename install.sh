#!/bin/bash
# Installs Encore.
#
#   curl -fsSL https://raw.githubusercontent.com/chachasmooth/Encore/main/install.sh | bash
#
# Piping a URL into a shell means trusting whoever controls that URL. The whole
# script is short and readable above the fold on purpose. If you would rather
# not, the README has the same three steps to do by hand.

set -euo pipefail

REPO="chachasmooth/Encore"
URL="https://github.com/$REPO/releases/latest/download/Encore.zip"
DEST="/Applications"

[ "$(uname -s)" = "Darwin" ] || { echo "Encore is macOS only."; exit 1; }
[ "$(uname -m)" = "arm64" ] || {
    echo "Encore needs Apple Silicon (M1 or newer). This Mac is $(uname -m)."
    exit 1
}

# Fall back to a per-user location rather than asking for a password.
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

cat <<INFO
Encore installer

  1. Download the latest release from github.com/$REPO
  2. Install it to $DEST
  3. Clear the macOS quarantine flag

Step 3 is needed because Encore is not signed with a paid Apple Developer
certificate, so macOS refuses to open it as an unidentified download. Source is
at github.com/$REPO if you would rather build it yourself.

INFO

TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

echo "Downloading..."
curl -fsSL "$URL" -o "$TEMP/Encore.zip"

echo "Unpacking..."
ditto -x -k "$TEMP/Encore.zip" "$TEMP"
[ -d "$TEMP/Encore.app" ] || { echo "The download did not contain Encore.app."; exit 1; }

# A running copy cannot be replaced.
if pgrep -xq Encore; then
    echo "Quitting the running copy..."
    osascript -e 'quit app "Encore"' 2>/dev/null || pkill -x Encore || true
    sleep 2
fi

echo "Installing to $DEST..."
rm -rf "$DEST/Encore.app"
mv "$TEMP/Encore.app" "$DEST/"

echo "Clearing quarantine..."
xattr -dr com.apple.quarantine "$DEST/Encore.app"

# Verify rather than assume. If the app was running and refused to quit, the
# copy above fails and the old build stays put, which is impossible to spot
# from the outside and wasted a lot of testing.
INSTALLED="$(defaults read "$DEST/Encore.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo unknown)"
echo "Installed version: $INSTALLED"

cat <<DONE

Installed to $DEST/Encore.app

Open it with:  open -a Encore

Run it on both Macs. On the one you want to extend choose "Extend this Mac";
on the spare choose "Be the second screen" and type in the code.
DONE
