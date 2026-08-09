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
# serving the old binary.
#
# `pkill` alone is not enough either. The LaunchAgent is KeepAlive, so launchd
# respawns the app within a second or so of the kill, and the respawn can land
# between the copy and the `codesign` below -- which then fails against a
# running binary with "Bad file descriptor" and leaves an unsigned bundle. So
# the agent is stopped properly when it is loaded, and restarted at the end.
LABEL="com.momentumminds.claude-meter"
RELOAD=0
if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  RELOAD=1
fi
pkill -f "ClaudeMeter.app/Contents/MacOS/ClaudeMeter" 2>/dev/null || true
# Wait for it to actually go, rather than assuming the signal was instant.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -f "ClaudeMeter.app/Contents/MacOS/ClaudeMeter" >/dev/null 2>&1 || break
  sleep 0.2
done

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/ClaudeMeter" "$APP_DIR/Contents/MacOS/"
cp scripts/Info.plist "$APP_DIR/Contents/Info.plist"

# Ad-hoc sign so Launch Services treats it as a real app rather than a loose
# binary. Must run after the Info.plist is in place so the signature covers it.
codesign --force --deep --sign - "$APP_DIR"

# Read it back. A signature that failed to apply produces a bundle that looks
# built and is not, and the failure above is intermittent by nature -- it
# depends on whether launchd got there first.
codesign --verify --deep --strict "$APP_DIR" ||
  { echo "codesign verification failed for $APP_DIR" >&2; exit 1; }

# Register with Launch Services so `open` and login items resolve the bundle.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR"

if [ "$RELOAD" = 1 ]; then
  launchctl bootstrap "gui/$UID" "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null ||
    launchctl kickstart -k "gui/$UID/$LABEL" 2>/dev/null || true
  echo "Restarted $LABEL"
fi

echo ""
echo "Built $APP_DIR"
echo "Run: open '$APP_DIR'"
