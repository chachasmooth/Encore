#!/bin/bash
# Installs Understudy.
#
#   curl -fsSL https://raw.githubusercontent.com/chachasmooth/Understudy/main/install.sh | bash
#
# Piping a URL into a shell means trusting whoever controls that URL. The whole
# script is short and readable above the fold on purpose. If you would rather
# not, the README has the same three steps to do by hand.

set -euo pipefail

REPO="chachasmooth/Understudy"
URL="https://github.com/$REPO/releases/latest/download/Understudy.zip"
DEST="/Applications"

[ "$(uname -s)" = "Darwin" ] || { echo "Understudy is macOS only."; exit 1; }
[ "$(uname -m)" = "arm64" ] || {
    echo "Understudy needs Apple Silicon (M1 or newer). This Mac is $(uname -m)."
    exit 1
}

# Fall back to a per-user location rather than asking for a password.
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

cat <<INFO
Understudy installer

  1. Download the latest release from github.com/$REPO
  2. Install it to $DEST
  3. Clear the macOS quarantine flag

Step 3 is needed because Understudy is not signed with a paid Apple Developer
certificate, so macOS refuses to open it as an unidentified download. Source is
at github.com/$REPO if you would rather build it yourself.

INFO

TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

echo "Downloading..."
curl -fsSL "$URL" -o "$TEMP/Understudy.zip"

echo "Unpacking..."
ditto -x -k "$TEMP/Understudy.zip" "$TEMP"
[ -d "$TEMP/Understudy.app" ] || { echo "The download did not contain Understudy.app."; exit 1; }

# A running copy cannot be replaced.
if pgrep -xq Understudy; then
    echo "Quitting the running copy..."
    osascript -e 'quit app "Understudy"' 2>/dev/null || pkill -x Understudy || true
    sleep 2
fi

echo "Installing to $DEST..."
rm -rf "$DEST/Understudy.app"
mv "$TEMP/Understudy.app" "$DEST/"

echo "Clearing quarantine..."
xattr -dr com.apple.quarantine "$DEST/Understudy.app"

cat <<DONE

Installed to $DEST/Understudy.app

Open it with:  open -a Understudy

Run it on both Macs. On the one you want to extend choose "Extend this Mac";
on the spare choose "Be the second screen" and type in the code.
DONE
