#!/bin/bash
# Install claude-meter: build the app, wire the status line, register the
# Claude Code hooks, and load the LaunchAgent.
#
# Safe to re-run. Every step is idempotent and skips work already done.
#
# The one rule this script follows above all others: never claim success it has
# not verified. The status line is the only channel that carries rate_limits, so
# an install that quietly fails to wire it produces a menubar item that is
# permanently empty and indistinguishable from an idle one. Every step that
# changes something reads the result back before reporting it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
COLLECT="$ROOT/bin/claude-meter-collect"
CHAIN="$HOME/.kickbacks/cli-prev-statusline.json"
LABEL="com.momentumminds.claude-meter"
PLIST_SRC="$ROOT/scripts/$LABEL.plist.template"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
# Pre-rename label, booted out below so an upgrade does not leave two agents
# fighting over the same menubar item.
LEGACY_LABEL="com.mathias.claude-meter"

fail() { printf '\nInstall stopped: %s\n' "$1" >&2; exit 1; }

# ------------------------------------------------------------- preflight --

echo "==> Checking prerequisites"

# jq is resolved from PATH rather than assumed at /usr/bin/jq, so a Homebrew
# install counts. Every script in bin/ does the same, and they all degrade to a
# silent no-op without it -- which is exactly the failure this script exists to
# stop shipping.
JQ="$(command -v jq || true)"
[ -n "$JQ" ] || fail "jq not found. Install it with: brew install jq"
"$JQ" -n . >/dev/null 2>&1 ||
  fail "jq at $JQ does not run. Reinstall it with: brew install jq"

command -v swift >/dev/null 2>&1 ||
  fail "swift not found. Install the Xcode command line tools: xcode-select --install"
xcode-select -p >/dev/null 2>&1 ||
  fail "no developer directory. Run: xcode-select --install"

# Everything below writes into settings.json; refuse to touch a file that does
# not parse rather than overwrite it with the result of a failed jq run.
if [ -f "$SETTINGS" ]; then
  "$JQ" -e . "$SETTINGS" >/dev/null 2>&1 ||
    fail "$SETTINGS is not valid JSON. Fix or move it, then re-run."
fi

echo "    jq $("$JQ" --version 2>/dev/null), $(swift --version 2>&1 | head -1)"

# Writes a jq program's output over settings.json through a temp file. Redirect-
# ing jq straight at the file truncates it before jq even runs, so a jq failure
# leaves settings.json at zero bytes -- the collector's temp-then-rename is the
# pattern to copy, not the one to skip.
settings_apply() {
  local tmp="$SETTINGS.claude-meter.tmp.$$"
  if "$JQ" "$@" "$SETTINGS" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv -f "$tmp" "$SETTINGS"
  else
    rm -f "$tmp"
    return 1
  fi
}

# One backup of the state before claude-meter first touched anything. Written
# once and never overwritten, so re-running the installer cannot bury the
# original under a copy of our own output.
settings_backup_once() {
  [ -f "$SETTINGS" ] || return 0
  [ -e "$SETTINGS.claude-meter-bak" ] && return 0
  cp "$SETTINGS" "$SETTINGS.claude-meter-bak"
  echo "    backed up settings.json to $SETTINGS.claude-meter-bak"
}

# ----------------------------------------------------------------- build --

echo ""
echo "==> Building ClaudeMeter.app"
"$ROOT/scripts/build-app.sh"

# --------------------------------------------------------- status line --

echo ""
echo "==> Status line"

# What the collector must end up wired into, and how it got there. Verified by
# reading the config back at the end rather than assumed from the branch taken.
WIRED_VIA=""

if [ -d "$HOME/.kickbacks" ]; then
  # The statusLine slot belongs to the kickbacks ad script, which rewrites it.
  # claude-meter hangs off the chain hook kickbacks provides instead of fighting
  # for the slot -- see bin/claude-meter-session-start.
  CLAUDE_METER_COLLECT="$COLLECT" "$ROOT/bin/claude-meter-session-start" </dev/null || true
  WIRED_VIA="chain"
else
  # No kickbacks: claude-meter owns statusLine directly. An existing status line
  # is somebody's deliberate choice, so it is reported, never replaced.
  current=""
  if [ -f "$SETTINGS" ]; then
    current=$("$JQ" -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)
  fi

  if [ "$current" = "$COLLECT" ]; then
    echo "    already pointing at $COLLECT"
  elif [ -n "$current" ]; then
    cat >&2 <<EOF

Your status line is already set to another command:

    $current

claude-meter will not replace it. Either point it at the collector yourself:

    jq '.statusLine = {"type":"command","command":"$COLLECT"}' \\
      "$SETTINGS" > "$SETTINGS.new" && mv "$SETTINGS.new" "$SETTINGS"

or keep your command and chain the collector from inside it -- it reads the
same stdin and prints one line.
EOF
    fail "status line already in use; nothing was changed"
  else
    mkdir -p "$(dirname "$SETTINGS")"
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    settings_backup_once
    settings_apply --arg c "$COLLECT" \
      '.statusLine = {"type":"command","command":$c}' ||
      fail "could not write statusLine into $SETTINGS"
    echo "    set statusLine to $COLLECT"
  fi
  WIRED_VIA="settings"
fi

# ----------------------------------------------------------------- hooks --

echo ""
echo "==> Claude Code hooks"

# SessionEnd removes a closed session's snapshot so the avatar can tell "closed"
# from "idle"; SessionStart re-asserts whichever channel is carrying the data.
#
# Both are appended, not assigned. Assigning the array replaces whatever else
# the user has registered for that event -- their own hook disappears silently
# and they will never connect it to installing this. The strip-then-append keeps
# re-runs idempotent without being blind to anyone else's entries.
if [ ! -f "$SETTINGS" ]; then
  echo "    $SETTINGS not found; skipping"
else
  settings_backup_once
  settings_apply --arg start "$ROOT/bin/claude-meter-session-start" \
                 --arg end   "$ROOT/bin/claude-meter-session-end" '
    def strip($event; $cmd):
      .hooks[$event] = (
        (.hooks[$event] // [])
        | map(.hooks = ((.hooks // []) | map(select(.command != $cmd))))
        | map(select(((.hooks // []) | length) > 0))
      );
    def ensure($event; $cmd):
      strip($event; $cmd)
      | .hooks[$event] += [{"hooks":[{"type":"command","command":$cmd,"timeout":5}]}];
    (.hooks //= {})
    | ensure("SessionStart"; $start)
    | ensure("SessionEnd"; $end)
  ' || fail "could not register hooks in $SETTINGS"
  echo "    SessionStart and SessionEnd registered"
fi

# ---------------------------------------------------------- LaunchAgent --

echo ""
echo "==> LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
# launchd cannot expand ~ or $HOME, so the template's absolute paths are filled
# in here rather than checked in pointing at one person's home.
sed -e "s|__ROOT__|$ROOT|g" -e "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"

if [ "$LEGACY_LABEL" != "$LABEL" ]; then
  launchctl bootout "gui/$UID/$LEGACY_LABEL" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
fi

# launchd does not pick up plist edits on its own -- bootout then bootstrap.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST_DST"
echo "    loaded $LABEL"

# ---------------------------------------------------------------- verify --

echo ""
echo "==> Verifying"

wired=""
case "$WIRED_VIA" in
  chain)
    [ -f "$CHAIN" ] &&
      wired=$("$JQ" -r '.statusLine.command // empty' "$CHAIN" 2>/dev/null || true)
    ;;
  settings)
    [ -f "$SETTINGS" ] &&
      wired=$("$JQ" -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)
    ;;
esac

if [ "$wired" != "$COLLECT" ]; then
  cat >&2 <<EOF

The collector is NOT connected, so the menubar item will stay empty.

  expected: $COLLECT
  found:    ${wired:-nothing}
EOF
  if [ "$WIRED_VIA" = "chain" ]; then
    echo "  in:       $CHAIN" >&2
  else
    echo "  in:       $SETTINGS (.statusLine.command)" >&2
  fi
  fail "status line not wired"
fi

hooks_ok=$("$JQ" -r --arg end "$ROOT/bin/claude-meter-session-end" \
  '[.. | .command? // empty] | index($end) != null' "$SETTINGS" 2>/dev/null || echo false)
[ "$hooks_ok" = "true" ] || echo "    warning: SessionEnd hook not found in $SETTINGS" >&2

echo "    collector wired via ${WIRED_VIA/settings/settings.json}"
echo "    app running from $ROOT/dist/ClaudeMeter.app"

cat <<EOF

Done. Send one message in any Claude Code session to populate the menubar item.

This checkout is load-bearing: the LaunchAgent and both hooks point at
$ROOT. If you move it, re-run ./install.sh from the new location.
EOF
