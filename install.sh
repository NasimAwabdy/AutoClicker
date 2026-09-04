#!/bin/bash
# Installs (or updates to) the latest AutoClicker release. Usage:
#   curl -fsSL https://raw.githubusercontent.com/NasimAwabdy/AutoClicker/main/install.sh | bash
set -euo pipefail

REPO="NasimAwabdy/AutoClicker"
APP="/Applications/AutoClicker.app"

echo "Fetching latest release…"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | grep -o '"browser_download_url": *"[^"]*AutoClicker\.zip"' \
      | grep -o 'https://[^"]*')
[ -n "$URL" ] || { echo "No AutoClicker.zip found in the latest release." >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/AutoClicker.zip"
ditto -x -k "$TMP/AutoClicker.zip" "$TMP"

# Quit any running instance so the binary can be replaced cleanly.
pkill -f "AutoClicker.app/Contents/MacOS/AutoClicker" 2>/dev/null && sleep 0.5 || true
rm -rf "$APP"
ditto "$TMP/AutoClicker.app" "$APP"

# Downloaded apps are quarantined, and this build is ad-hoc signed (not
# notarized), so Gatekeeper would refuse to open it without this.
xattr -dr com.apple.quarantine "$APP"

# The ad-hoc signature changes every release, which strands a stale
# Accessibility grant that silently blocks clicks — reset for a clean re-grant.
tccutil reset Accessibility local.autoclicker.app >/dev/null 2>&1 || true

VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
echo "✅ Installed AutoClicker $VERSION to $APP"
echo "Open it and re-grant Accessibility permission when prompted"
echo "(required after every update — the code signature changes)."
