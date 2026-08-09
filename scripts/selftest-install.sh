#!/bin/bash
# Headless tests for install.sh and the two hook scripts.
#
# The installer is the most dangerous code in this project: it edits
# ~/.claude/settings.json, a file the user shares with every other Claude Code
# tool they have. It is also the code most likely to be wrong for someone who is
# not the author, because the author's machine only ever exercises one path
# through it. So it is tested against a fake $HOME, a fake checkout, and stubbed
# swift/launchctl -- nothing here touches the real machine.
#
# Run: ./scripts/selftest-install.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOX="$(mktemp -d "${TMPDIR:-/tmp}/claude-meter-selftest.XXXXXX")"
trap 'rm -rf "$BOX"' EXIT
# $TMPDIR ends in a slash on macOS, so mktemp hands back a path with a doubled
# separator. The scripts under test resolve their own root with `cd && pwd`,
# which normalises it -- compare against the same normalised form or every path
# assertion fails on a difference the user would never see.
BOX="$(cd "$BOX" && pwd)"

pass=0; fails=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fails=$((fails + 1)); printf '  FAIL %s\n' "$1"; }

# A PATH with every real tool except jq, so "user has no jq" can be tested
# without the test itself losing sed, cp and friends.
NOJQ="$BOX/nojq"; mkdir -p "$NOJQ"
for d in /bin /usr/bin /usr/sbin /sbin; do
  for f in "$d"/*; do
    b="${f##*/}"
    [ "$b" = jq ] && continue
    [ -e "$NOJQ/$b" ] || ln -s "$f" "$NOJQ/$b" 2>/dev/null
  done
done

# Rebuilds the sandbox: a throwaway $HOME, a copy of the checkout whose build
# step is stubbed, and shims for the two commands that would otherwise touch the
# real system.
setup() {
  rm -rf "$BOX/home" "$BOX/root" "$BOX/shim"
  mkdir -p "$BOX/home/.claude" "$BOX/shim" "$BOX/root/scripts"
  cp -R "$ROOT/bin" "$BOX/root/bin"
  cp "$ROOT/install.sh" "$BOX/root/install.sh"
  cp "$ROOT/scripts/com.momentumminds.claude-meter.plist.template" "$BOX/root/scripts/"
  printf '#!/bin/bash\nmkdir -p "$(dirname "$0")/../dist"\n' > "$BOX/root/scripts/build-app.sh"
  printf '#!/bin/bash\nexit 0\n'                              > "$BOX/shim/launchctl"
  printf '#!/bin/bash\necho "swift-stub"\n'                   > "$BOX/shim/swift"
  printf '#!/bin/bash\necho /Library/Developer/CommandLineTools\n' > "$BOX/shim/xcode-select"
  chmod +x "$BOX/root/scripts/build-app.sh" "$BOX/shim/"*
}

install_run() {   # install_run [extra PATH prefix]
  HOME="$BOX/home" PATH="$BOX/shim:${1:-$PATH}" \
    bash "$BOX/root/install.sh" > "$BOX/out" 2>&1
  echo $?
}
hook_start() { HOME="$BOX/home" bash "$BOX/root/bin/claude-meter-session-start" </dev/null; }
S()          { cat "$BOX/home/.claude/settings.json" 2>/dev/null; }
COLLECT()    { echo "$BOX/root/bin/claude-meter-collect"; }
CHAIN="$BOX/home/.kickbacks/cli-prev-statusline.json"

echo "install.sh"

echo "  · clean machine, no kickbacks, no settings.json"
setup; rm -f "$BOX/home/.claude/settings.json"
rc=$(install_run)
[ "$rc" = 0 ] && ok "exits 0" || { bad "exit $rc"; cat "$BOX/out"; }
[ "$(S | jq -r '.statusLine.command')" = "$(COLLECT)" ] &&
  ok "wires statusLine at this checkout" || bad "statusLine: $(S | jq -c .statusLine)"

echo "  · a status line the user already set is refused, never replaced"
setup; echo '{"statusLine":{"type":"command","command":"/usr/local/bin/mine"},"model":"opus"}' \
  > "$BOX/home/.claude/settings.json"
before=$(S); rc=$(install_run)
[ "$rc" != 0 ] && ok "exits non-zero" || bad "exited 0"
[ "$(S)" = "$before" ] && ok "settings.json untouched" || bad "settings.json mutated"
grep -q "Done." "$BOX/out" && bad "still printed Done" || ok "does not print Done"

echo "  · another tool's hooks survive, ours are appended"
setup
cat > "$BOX/home/.claude/settings.json" <<'EOF'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"OTHER_START"}]}],
          "SessionEnd":[{"hooks":[{"type":"command","command":"OTHER_END"}]}]},
 "spinnerVerbs":["x"]}
EOF
rc=$(install_run)
[ "$rc" = 0 ] && ok "exits 0" || { bad "exit $rc"; cat "$BOX/out"; }
S | jq -e '[.. | .command? // empty] | index("OTHER_START") != null and (index("OTHER_END") != null)' \
  >/dev/null && ok "foreign hooks preserved" || bad "foreign hooks lost: $(S | jq -c .hooks)"
S | jq -e --arg c "$BOX/root/bin/claude-meter-session-end" \
  '[.. | .command? // empty] | index($c) != null' >/dev/null &&
  ok "our hooks registered" || bad "our hooks missing"
S | jq -e '.spinnerVerbs == ["x"]' >/dev/null &&
  ok "unrelated keys kept" || bad "unrelated keys lost"

echo "  · re-running does not duplicate anything"
rc=$(install_run)
n=$(S | jq '[.. | .command? // empty] | map(select(test("claude-meter-session"))) | length')
[ "$n" = 2 ] && ok "exactly two of ours" || bad "$n of ours"

echo "  · no jq: fails before touching settings.json"
setup; echo '{"keep":"me"}' > "$BOX/home/.claude/settings.json"
rc=$(install_run "$NOJQ")
[ "$rc" != 0 ] && ok "exits non-zero" || bad "exited 0"
[ -s "$BOX/home/.claude/settings.json" ] &&
  ok "settings.json not truncated" || bad "settings.json truncated to 0 bytes"
grep -q "brew install jq" "$BOX/out" && ok "names the fix" || bad "no fix named"

echo "  · a jq that exists but will not run is diagnosed as jq's fault"
setup; echo '{"keep":"me"}' > "$BOX/home/.claude/settings.json"
printf '#!/bin/bash\nexit 127\n' > "$BOX/shim/jq"; chmod +x "$BOX/shim/jq"
rc=$(install_run)
[ "$rc" != 0 ] && ok "exits non-zero" || bad "exited 0"
grep -q "does not run" "$BOX/out" && ok "blames jq, not the JSON" || bad "misdiagnosed"
[ -s "$BOX/home/.claude/settings.json" ] && ok "settings.json intact" || bad "truncated"

echo "  · unparseable settings.json is refused, not overwritten"
setup; printf '{ not json' > "$BOX/home/.claude/settings.json"
before=$(S); rc=$(install_run)
[ "$rc" != 0 ] && ok "exits non-zero" || bad "exited 0"
[ "$(S)" = "$before" ] && ok "left alone" || bad "clobbered"

echo "  · with kickbacks, from a checkout that is not ~/claude-meter"
setup; mkdir -p "$BOX/home/.kickbacks"
echo '{"statusLine":{"type":"command","command":"/usr/local/bin/old"}}' > "$CHAIN"
echo '{}' > "$BOX/home/.claude/settings.json"
rc=$(install_run)
[ "$rc" = 0 ] && ok "exits 0" || { bad "exit $rc"; cat "$BOX/out"; }
[ "$(jq -r '.statusLine.command' "$CHAIN")" = "$(COLLECT)" ] &&
  ok "chain points at this checkout" || bad "chain: $(jq -c . "$CHAIN")"
[ -f "$CHAIN.claude-meter-bak" ] && ok "displaced command backed up" || bad "no backup"
jq -e '.statusLine == null' "$BOX/home/.claude/settings.json" >/dev/null &&
  ok "settings.json statusLine left to kickbacks" || bad "wrote statusLine too"

echo ""
echo "hooks"

echo "  · SessionStart re-asserts a hijacked chain without burying the backup"
echo '{"statusLine":{"type":"command","command":"/tmp/hijack"}}' > "$CHAIN"
hook_start
[ "$(jq -r '.statusLine.command' "$CHAIN")" = "$(COLLECT)" ] &&
  ok "chain restored" || bad "chain: $(jq -c . "$CHAIN")"
[ "$(jq -r '.statusLine.command' "$CHAIN.claude-meter-bak")" = "/usr/local/bin/old" ] &&
  ok "original backup preserved" || bad "backup overwritten"

echo "  · SessionStart leaves a status line the user chose alone"
setup; echo '{"statusLine":{"type":"command","command":"/usr/local/bin/mine"}}' \
  > "$BOX/home/.claude/settings.json"
hook_start
[ "$(S | jq -r '.statusLine.command')" = "/usr/local/bin/mine" ] &&
  ok "untouched" || bad "overwrote it"

echo "  · SessionStart claims an empty statusLine when there is no kickbacks"
setup; echo '{}' > "$BOX/home/.claude/settings.json"
hook_start
[ "$(S | jq -r '.statusLine.command')" = "$(COLLECT)" ] &&
  ok "claimed" || bad "statusLine: $(S | jq -c .statusLine)"

echo ""
echo "collector"

PAYLOAD='{"session_id":"aaaa-bbbb","model":{"display_name":"Opus 5"},
 "context_window":{"used_percentage":22,"total_input_tokens":225000,"context_window_size":1000000},
 "cost":{"total_cost_usd":8.34},
 "rate_limits":{"five_hour":{"used_percentage":41},"seven_day":{"used_percentage":15}}}'
collect() { CLAUDE_METER_STATE="$BOX/state" "$@" bash "$ROOT/bin/claude-meter-collect" |
              sed 's/\x1b\[[0-9;]*m//g'; }

echo "  · cost survives a comma-decimal locale"
out=$(printf '%s' "$PAYLOAD" | collect env LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8)
case "$out" in *'$8.34'*) ok "renders \$8.34" ;; *) bad "got: $out" ;; esac
out=$(printf '%s' "$PAYLOAD" | collect)
case "$out" in *'$8.34'*) ok "unchanged in the default locale" ;; *) bad "got: $out" ;; esac

echo "  · an unparseable cost prints nothing, not two numbers"
out=$(printf '%s' '{"session_id":"x1","cost":{"total_cost_usd":"nope"}}' | collect 2>/dev/null)
case "$out" in *'$'*) bad "got: $out" ;; *) ok "cost dropped" ;; esac

echo "  · no jq: silent, exit 0, so the status line still renders"
out=$(printf '%s' "$PAYLOAD" | CLAUDE_METER_STATE="$BOX/state" PATH="$NOJQ" \
        bash "$ROOT/bin/claude-meter-collect"; printf 'rc=%s' "$?")
[ "$out" = "rc=0" ] && ok "prints nothing, exits 0" || bad "got: $out"

echo ""
echo "history trail"

# The append is sampled on a one-minute grid taken from the wall clock, so a
# test that just ran the collector twice would be a coin flip on whether the two
# calls straddled a minute boundary. Rather than add a knob to the collector for
# the tests to turn, the clock itself is stubbed: `date` is the only thing the
# collector asks about the time, and a shim first on PATH makes every run happen
# at an epoch this script chooses.
CLOCK="$BOX/clock"; mkdir -p "$CLOCK"
printf '#!/bin/bash\ncat "%s/now"\n' "$CLOCK" > "$CLOCK/date"; chmod +x "$CLOCK/date"

HSTATE="$BOX/hstate"; HIST="$HSTATE/history.jsonl"
RL='{"session_id":"h1","rate_limits":{
      "five_hour":{"used_percentage":41,"resets_at":1800000300},
      "seven_day":{"used_percentage":15,"resets_at":1800500000}}}'

at()     { printf '%s\n' "$1" > "$CLOCK/now"; }        # freeze the collector's clock
hrun()   { at "$1"; printf '%s' "$2" | CLAUDE_METER_STATE="$HSTATE" PATH="$CLOCK:$PATH" \
             bash "$ROOT/bin/claude-meter-collect" >/dev/null 2>&1; }
hlines() { wc -l < "$HIST" 2>/dev/null | tr -d ' '; }

echo "  · one refresh appends one line carrying both windows"
rm -rf "$HSTATE"
hrun 1800000000 "$RL"
[ "$(hlines)" = 1 ] && ok "one line" || bad "lines: $(hlines)"
jq -e '.ts == 1800000000 and .five_hour_pct == 41 and .five_hour_reset == 1800000300
       and .seven_day_pct == 15 and .seven_day_reset == 1800500000' "$HIST" >/dev/null &&
  ok "ts, both percentages, both resets" || bad "line: $(cat "$HIST")"

echo "  · a second refresh inside the same minute is suppressed"
hrun 1800000030 "$RL"; hrun 1800000059 "$RL"
[ "$(hlines)" = 1 ] && ok "still one line" || bad "lines: $(hlines)"
hrun 1800000060 "$RL"
[ "$(hlines)" = 2 ] && ok "the next minute appends again" || bad "lines: $(hlines)"

echo "  · concurrent sessions see the same account numbers and write one line"
at 1800000120
for i in 1 2 3 4 5 6; do
  printf '%s' "$RL" | CLAUDE_METER_STATE="$HSTATE" PATH="$CLOCK:$PATH" \
    bash "$ROOT/bin/claude-meter-collect" >/dev/null 2>&1 &
done
wait
[ "$(hlines)" = 3 ] && ok "six at once, one line" || bad "lines: $(hlines)"

echo "  · absent stays absent"
hrun 1800000180 '{"session_id":"h2","cost":{"total_cost_usd":1}}'
[ "$(hlines)" = 3 ] && ok "no rate_limits appends nothing" || bad "appended: $(tail -1 "$HIST")"
hrun 1800000240 '{"session_id":"h3","rate_limits":{"five_hour":{"used_percentage":7}}}'
tail -1 "$HIST" | jq -e '.five_hour_pct == 7 and .five_hour_reset == null
                         and .seven_day_pct == null' >/dev/null &&
  ok "a missing window is null, never 0" || bad "line: $(tail -1 "$HIST")"

echo "  · an oversized trail is trimmed to the retention window, not to nothing"
# 26k lines nine days old and 4k lines a day old: over the 2 MB trigger, and
# straddling the 8-day cutoff so the trim has to keep one side and drop the
# other. The collector's own append makes 4001 the correct survivor count.
awk 'BEGIN {
  for (i = 0; i < 26000; i++) print "{\"ts\":1799000000,\"five_hour_pct\":41,\"five_hour_reset\":1800000300,\"seven_day_pct\":15,\"seven_day_reset\":1800500000}"
  for (i = 0; i <  4000; i++) print "{\"ts\":1800000000,\"five_hour_pct\":41,\"five_hour_reset\":1800000300,\"seven_day_pct\":15,\"seven_day_reset\":1800500000}"
}' > "$HIST"
hrun 1800100000 "$RL"
[ "$(hlines)" = 4001 ] && ok "expired dropped, recent kept" || bad "lines: $(hlines)"
[ "$(wc -c < "$HIST" | tr -d ' ')" -lt 2000000 ] &&
  ok "back under the byte cap" || bad "bytes: $(wc -c < "$HIST")"

echo "  · the 24h snapshot sweep does not reach the trail"
touch -t 202001010000 "$HIST"
hrun 1800100060 "$RL"
[ -f "$HIST" ] && [ "$(hlines)" = 4002 ] &&
  ok "an ancient history.jsonl survives" || bad "swept, or lines: $(hlines)"

echo "  · a state directory that cannot be written still renders the HUD"
RO="$BOX/readonly"; mkdir -p "$RO"; chmod 500 "$RO"
if printf '%s' "$PAYLOAD" | CLAUDE_METER_STATE="$RO/state" \
     bash "$ROOT/bin/claude-meter-collect" > "$BOX/hud.out" 2> "$BOX/hud.err"
then rc=0; else rc=$?; fi
chmod 700 "$RO"
[ "$rc" = 0 ] && ok "exits 0" || bad "exit $rc"
grep -q '5h 41%' "$BOX/hud.out" && ok "HUD still printed" || bad "no HUD: $(cat "$BOX/hud.out")"
[ ! -s "$BOX/hud.err" ] && ok "nothing on stderr" || bad "stderr: $(cat "$BOX/hud.err")"
[ ! -e "$RO/state" ] && ok "nothing created" || bad "wrote under an unwritable parent"

echo ""
echo "doctor"

JQ="$(command -v jq)"

# The doctor exists to name the cause when the menubar is empty, so what is
# tested here is the diagnosis, not just the exit code.
doctor_box() {
  setup
  # setup() only clears home/root/shim, and a state directory carried over from
  # the previous case would make "the collector has never run" untestable.
  rm -rf "$BOX/dstate"
  mkdir -p "$BOX/home/Library/LaunchAgents" "$BOX/dstate" \
           "$BOX/root/dist/ClaudeMeter.app/Contents/MacOS"
  : > "$BOX/root/dist/ClaudeMeter.app/Contents/MacOS/ClaudeMeter"
  chmod +x "$BOX/root/dist/ClaudeMeter.app/Contents/MacOS/ClaudeMeter"
  # launchctl is stubbed to "loaded and running" unless a case says otherwise.
  printf '#!/bin/bash\necho "\tstate = running"\necho "\tpid = 999"\n' > "$BOX/shim/launchctl"
  chmod +x "$BOX/shim/launchctl"
}
doctor() {
  HOME="$BOX/home" CLAUDE_METER_STATE="$BOX/dstate" PATH="$BOX/shim:${1:-$PATH}" \
    bash "$BOX/root/bin/claude-meter-doctor" > "$BOX/doc" 2>&1
  echo $?
}

echo "  · a fully wired machine passes"
doctor_box
: > "$BOX/home/Library/LaunchAgents/com.momentumminds.claude-meter.plist"
"$JQ" -n --arg c "$BOX/root/bin/claude-meter-collect" \
        --arg s "$BOX/root/bin/claude-meter-session-start" \
        --arg e "$BOX/root/bin/claude-meter-session-end" '
  {statusLine:{type:"command",command:$c},
   hooks:{SessionStart:[{hooks:[{type:"command",command:$s}]}],
          SessionEnd:[{hooks:[{type:"command",command:$e}]}]}}' \
  > "$BOX/home/.claude/settings.json"
echo '{"session_id":"x","rate_limits":{"five_hour":{"used_percentage":12,"resets_at":9999999999}}}' \
  > "$BOX/dstate/last-raw.json"
rc=$(doctor)
[ "$rc" = 0 ] && ok "exits 0" || { bad "exit $rc"; cat "$BOX/doc"; }
grep -q "Everything is wired" "$BOX/doc" && ok "says so" || bad "$(tail -1 "$BOX/doc")"

echo "  · an unwired status line is the failure it names first"
doctor_box
echo '{}' > "$BOX/home/.claude/settings.json"
rc=$(doctor)
[ "$rc" = 1 ] && ok "exits 1" || bad "exit $rc"
grep -q "no status line command is set" "$BOX/doc" &&
  ok "names the status line" || bad "$(grep fail "$BOX/doc" | head -1)"

echo "  · a status line from another checkout is distinguished from a stranger's"
doctor_box
"$JQ" -n --arg c "/somewhere/else/bin/claude-meter-collect" \
  '{statusLine:{type:"command",command:$c}}' > "$BOX/home/.claude/settings.json"
doctor >/dev/null
grep -q "different checkout" "$BOX/doc" &&
  ok "recognises its own collector" || bad "$(grep -A2 'points somewhere' "$BOX/doc" | tail -1)"

echo "  · a collector that has never run is not confused with an idle one"
doctor_box
"$JQ" -n --arg c "$BOX/root/bin/claude-meter-collect" \
  '{statusLine:{type:"command",command:$c}}' > "$BOX/home/.claude/settings.json"
rc=$(doctor)
grep -q "the collector has never run" "$BOX/doc" &&
  ok "says it has never run" || bad "$(grep fail "$BOX/doc" | head -1)"
[ "$rc" = 1 ] && ok "exits 1" || bad "exit $rc"

echo "  · Console billing is a warning, not a failure"
doctor_box
: > "$BOX/home/Library/LaunchAgents/com.momentumminds.claude-meter.plist"
"$JQ" -n --arg c "$BOX/root/bin/claude-meter-collect" \
        --arg s "$BOX/root/bin/claude-meter-session-start" \
        --arg e "$BOX/root/bin/claude-meter-session-end" '
  {statusLine:{type:"command",command:$c},
   hooks:{SessionStart:[{hooks:[{type:"command",command:$s}]}],
          SessionEnd:[{hooks:[{type:"command",command:$e}]}]}}' \
  > "$BOX/home/.claude/settings.json"
echo '{"session_id":"x","cost":{"total_cost_usd":1}}' > "$BOX/dstate/last-raw.json"
rc=$(doctor)
[ "$rc" = 0 ] && ok "exits 0" || bad "exit $rc"
grep -q "no rate limits in the last payload" "$BOX/doc" &&
  ok "explains why" || bad "no explanation"

echo "  · no jq is reported as the first thing to fix"
doctor_box
rc=$(doctor "$NOJQ")
[ "$rc" = 1 ] && ok "exits 1" || bad "exit $rc"
grep -q "brew install jq" "$BOX/doc" && ok "names the fix" || bad "no fix named"

echo ""
printf '%d passed, %d failed\n' "$pass" "$fails"
[ "$fails" -eq 0 ]
