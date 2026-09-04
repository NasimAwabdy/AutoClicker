#!/bin/bash
# Builds distributable installers: AutoClicker.pkg and AutoClicker.dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"
APP="build/AutoClicker.app"

# Ensure a fresh app build exists
./build.sh

rm -rf dist
mkdir -p dist

# ── .pkg installer ── double-click → installs straight into /Applications
pkgbuild \
    --component "$APP" \
    --identifier local.autoclicker.pkg \
    --version "$VERSION" \
    --install-location /Applications \
    "dist/AutoClicker-$VERSION.pkg" >/dev/null

# ── .dmg disk image ── classic drag-app-to-Applications layout
STAGING="dist/.dmg-staging"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/AutoClicker.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "AutoClicker" -srcfolder "$STAGING" \
    -ov -format UDZO "dist/AutoClicker-$VERSION.dmg" >/dev/null
rm -rf "$STAGING"

echo ""
echo "📦 Installers created:"
ls -lh dist/*.pkg dist/*.dmg | awk '{print "   " $NF " (" $5 ")"}'
echo ""
echo "Install with either:"
echo "   open dist/AutoClicker-$VERSION.pkg   # guided installer → /Applications"
echo "   open dist/AutoClicker-$VERSION.dmg   # drag AutoClicker to Applications"
