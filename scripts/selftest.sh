#!/bin/bash
# Behaviour tests for the pieces that are hard to eyeball in a menubar app:
# directory watching, mood aggregation, liveness/staleness, and tolerance of
# the shapes Claude Code actually produces (absent rate_limits, null
# used_percentage, a half-written file).
#
# Not a SwiftPM test target on purpose -- `swift test` needs XCTest from a full
# Xcode toolchain, and this machine builds against CommandLineTools. This
# compiles the same sources the app uses and runs them headless.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)/claude-meter-selftest"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "Compiling self-test..."
swiftc -o "$OUT" \
  "$ROOT/Sources/ClaudeMeter/Models.swift" \
  "$ROOT/Sources/ClaudeMeter/Mood.swift" \
  "$ROOT/Sources/ClaudeMeter/SnapshotStore.swift" \
  "$ROOT/scripts/selftest/main.swift" 2>&1 | grep -v "ld: warning" || true

echo ""
# Runs against a temporary CLAUDE_METER_STATE, never the real snapshot
# directory -- the test writes and deletes files freely.
"$OUT"
