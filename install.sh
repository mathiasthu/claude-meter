#!/bin/bash
# Install claude-meter: build the app, wire the status line chain, register the
# Claude Code hooks, and load the LaunchAgent.
#
# Safe to re-run. Every step is idempotent and skips work already done.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
JQ=/usr/bin/jq
SETTINGS="$HOME/.claude/settings.json"
PLIST_SRC="$ROOT/scripts/com.mathias.claude-meter.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.mathias.claude-meter.plist"
LABEL="com.mathias.claude-meter"

echo "==> Building ClaudeMeter.app"
"$ROOT/scripts/build-app.sh"

echo ""
echo "==> Status line chain"
# The statusLine slot in settings.json belongs to the kickbacks ad script,
# which rewrites it. claude-meter hangs off the chain hook kickbacks provides
# instead of replacing it -- see bin/claude-meter-session-start.
if [ -d "$HOME/.kickbacks" ]; then
  "$ROOT/bin/claude-meter-session-start" </dev/null
  echo "    chained via ~/.kickbacks/cli-prev-statusline.json"
else
  echo "    kickbacks not installed. Point statusLine at:"
  echo "      $ROOT/bin/claude-meter-collect"
fi

echo ""
echo "==> Claude Code hooks"
if [ ! -f "$SETTINGS" ]; then
  echo "    $SETTINGS not found; skipping. Add SessionStart/SessionEnd by hand."
elif "$JQ" -e '.hooks.SessionEnd' "$SETTINGS" >/dev/null 2>&1; then
  echo "    already present"
else
  # SessionEnd removes a closed session's snapshot so the avatar can tell
  # "closed" from "idle"; SessionStart re-asserts the chain file.
  cp "$SETTINGS" "$SETTINGS.claude-meter-bak"
  "$JQ" --arg start "$ROOT/bin/claude-meter-session-start" \
        --arg end   "$ROOT/bin/claude-meter-session-end" '
    .hooks //= {} |
    .hooks.SessionStart = [{"hooks":[{"type":"command","command":$start,"timeout":5}]}] |
    .hooks.SessionEnd   = [{"hooks":[{"type":"command","command":$end,"timeout":5}]}]
  ' "$SETTINGS.claude-meter-bak" > "$SETTINGS"
  echo "    added (previous settings at $SETTINGS.claude-meter-bak)"
fi

echo ""
echo "==> LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DST"
# launchd does not pick up plist edits on its own -- bootout then bootstrap.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST_DST"
echo "    loaded $LABEL"

echo ""
echo "Done. The menubar item appears once a Claude Code session refreshes its"
echo "status line -- send one message in any session to populate it."
