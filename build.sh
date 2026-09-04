#!/bin/bash
# Builds AutoClicker.app — no Xcode project needed, just Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

# Kill any running instance so 'open' launches the fresh build instead of pinging a zombie
pkill -f "AutoClicker.app/Contents/MacOS/AutoClicker" 2>/dev/null && sleep 0.5 || true

APP="build/AutoClicker.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -parse-as-library \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/AutoClicker" \
    -framework Cocoa -framework Carbon

# Ad-hoc sign so macOS remembers the Accessibility permission grant.
codesign --force --sign - "$APP"

# --no-install: build only (used by CI); skip the /Applications install.
if [[ "${1:-}" == "--no-install" ]]; then
    echo "✅ Built $APP"
    exit 0
fi

# Install to /Applications (stable path). Ad-hoc signatures change every build,
# which leaves a stale TCC entry that silently denies clicks ("Failed to match
# existing code requirement"), so wipe the permission for a clean re-grant.
# Also quit System Settings — it caches the stale Accessibility list.
killall "System Settings" 2>/dev/null || true
rm -rf /Applications/AutoClicker.app
ditto "$APP" /Applications/AutoClicker.app
tccutil reset Accessibility local.autoclicker.app >/dev/null 2>&1 || true

echo "✅ Built and installed /Applications/AutoClicker.app"
echo "Run with:  open /Applications/AutoClicker.app"
echo "⚠️  After each rebuild, re-grant Accessibility permission when prompted"
echo "   (the ad-hoc code signature changes, so macOS requires a fresh grant)."
