#!/bin/bash
# Behaviour tests for the pieces that are hard to eyeball in a menubar app:
# directory watching, state derivation, liveness/staleness, settings
# persistence and threshold ordering, every style rendering every state, and
# tolerance of the shapes Claude Code actually produces (absent rate_limits,
# null used_percentage, a half-written file).
#
# Not a SwiftPM test target on purpose -- `swift test` needs XCTest from a full
# Xcode toolchain, and this machine builds against CommandLineTools. This
# compiles the same sources the app uses and runs them headless.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
OUT="$TMP/claude-meter-selftest"
trap 'rm -rf "$TMP"' EXIT

# Everything except the app's own entry point, which would fight the harness
# for the `main` symbol.
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(
  find "$ROOT/Sources/ClaudeMeter" -name '*.swift' ! -name 'main.swift' | sort)

echo "Compiling self-test (${#SOURCES[@]} sources)..."
swiftc -o "$OUT" "${SOURCES[@]}" "$ROOT/scripts/selftest/main.swift" 2>&1 \
  | grep -v "ld: warning" || true

echo ""
# Runs against a temporary CLAUDE_METER_STATE and a throwaway UserDefaults
# suite, never the real snapshot directory or the user's preferences.
"$OUT"
