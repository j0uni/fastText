#!/bin/zsh
# Builds FastText.app and installs it into /Applications (override with DEST=...).
set -euo pipefail
cd "${0:A:h}/.."

DEST="${DEST:-/Applications}"
APP=build/FastText.app

make all

# Quit a running copy so the replacement is clean.
pkill -x FastText 2>/dev/null || true

rm -rf "$DEST/FastText.app"
ditto "$APP" "$DEST/FastText.app"
codesign --verify --strict "$DEST/FastText.app"

# Refresh Launch Services so "Open With" and the icon pick up the new bundle.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/FastText.app"

echo "Installed $DEST/FastText.app"
