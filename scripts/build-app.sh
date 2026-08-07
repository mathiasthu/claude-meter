#!/bin/bash
# Build ClaudeMeter.app from the SwiftPM executable.
#
# Adapted from whoop-data's Archive/build-menubar-app.sh, minus the WHOOP
# credential baking -- claude-meter has no secrets and reads only local files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG=release
BUILD_DIR=".build/$CONFIG"
APP_DIR="dist/ClaudeMeter.app"

echo "Building ClaudeMeter ($CONFIG)..."
swift build -c "$CONFIG" --product ClaudeMeter

# Replacing the bundle on disk is not enough on its own -- `open` activates an
# already-running app rather than respawning it, so a stale process keeps
# serving the old binary. Kill any running instance first.
pkill -f "ClaudeMeter.app/Contents/MacOS/ClaudeMeter" 2>/dev/null || true

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/ClaudeMeter" "$APP_DIR/Contents/MacOS/"
cp scripts/Info.plist "$APP_DIR/Contents/Info.plist"

# Ad-hoc sign so Launch Services treats it as a real app rather than a loose
# binary. Must run after the Info.plist is in place so the signature covers it.
codesign --force --deep --sign - "$APP_DIR"

# Register with Launch Services so `open` and login items resolve the bundle.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR"

echo ""
echo "Built $APP_DIR"
echo "Run: open '$APP_DIR'"
