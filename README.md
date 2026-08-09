# claude-meter

See your Claude Code 5-hour limit, weekly limit, and per-session context fill
without opening claude.ai.

A menubar item plus a floating avatar, fed by a collector that hangs off Claude
Code's status line.

```
menubar:      ◔ 5h 41% · 3h07m

avatar:       a small character on top of your windows, no window chrome,
              whose pose and colour track how close you are to a wall

status line:  5h 41% ·3h07m   7d 15%   ctx 22% 225k/1M   $8.34
              (stacked under the kickbacks ad line)
```

## Why it works this way

Claude Code delivers `rate_limits` (the 5-hour and 7-day windows) and
`context_window` to exactly one place: the **statusLine command's stdin**.
There is no local API, log, or file that carries the 5-hour number — the status
line is the only channel. So `bin/claude-meter-collect` runs as a status line
command and publishes what it receives; everything else reads those snapshots.

Two consequences worth knowing:

- **Nothing updates while no session is running.** The status line only fires on
  session start, new assistant messages, `/compact`, and permission/vim mode
  changes. With no session open there is no new data, so the avatar sleeps and
  shows the age of what it last saw rather than pretending a stale number is
  current. The exception is a rate-limit window that has passed its reset:
  those roll on a clock, so once `resets_at` is behind us the window reads 0%
  and says when it cleared, rather than holding the previous window's number.
- **`rate_limits` needs a Claude.ai subscription and one API response.** It is
  absent for Console billing, and absent in a brand new session until the first
  reply comes back. The UI shows "no limit data yet" rather than 0%.

For an authoritative on-demand check inside a session, `/usage` (alias `/cost`)
and `/context` are built in.

## Layout

| Path | What it does |
|---|---|
| `bin/claude-meter-collect` | Status line command. Publishes a snapshot per session, appends to the history trail, and prints the HUD line. |
| `bin/claude-meter-session-end` | `SessionEnd` hook. Deletes the snapshot so the avatar knows the session closed. |
| `bin/claude-meter-session-start` | `SessionStart` hook. Re-asserts the status line chain if something clobbered it. |
| `bin/claude-meter-doctor` | Says which part of the wiring is broken. Read-only. |
| `Sources/ClaudeMeter/` | The menubar app and floating avatar. |
| `scripts/build-app.sh` | Builds `dist/ClaudeMeter.app`. |
| `scripts/selftest.sh` | Headless tests for the store, moods, liveness, and malformed input. |
| `scripts/selftest-install.sh` | Headless tests for the installer, hooks, collector and doctor, against a fake `$HOME`. |
| `install.sh` | Does all of the wiring below. Idempotent. |

Snapshots live outside the repo, in `~/.local/state/claude-meter/`:

- `sessions/<session_id>.json` — one per session, rewritten on every status line refresh
- `last-raw.json` — the most recent raw status line payload, kept for debugging schema changes
- `history.jsonl` — the account's rate-limit history, one line a minute

### The history trail

The first two are overwrites. They answer "where am I right now" and nothing
else: `SessionEnd` deletes a session's file the moment it closes, and a 24-hour
sweep clears whatever died without firing the hook. `history.jsonl` is the one
thing here that accumulates.

```json
{"ts":1786243870,"five_hour_pct":11,"five_hour_reset":1786253400,"seven_day_pct":54,"seven_day_reset":1786474800}
```

- **One line a minute, for the account, not the session.** Both windows are
  account-level, so every session open right now reports the same two numbers.
  The collector claims a one-minute slot before it writes anything, which is why
  three sessions mid-answer leave one line rather than several a second.
- **Appended, never rewritten.** `>>` opens with `O_APPEND`, where the
  seek-to-end and the write are one indivisible step, and a line is ~113 bytes —
  short enough to be a single `write()`. Two collectors racing can interleave
  lines but not characters.
- **Absent is still not zero.** No `rate_limits` in the payload appends no line
  at all. One window present and the other missing writes an explicit `null`.
- **Eight days.** One more than the 7-day window, so a full 7-day window is
  always covered. Trimming only happens once the file passes 2 MB, and drops by
  age rather than by count.
- Skip a line you cannot parse. A crash mid-append can in principle leave a torn
  one; the next trim discards anything without a well-formed leading `ts`.

Nothing reads it yet. It exists so that burn rate, a 5-hour sparkline, and "will
this task outlive the window" become answerable later — none of them are while
every reading is thrown away a day after it arrives.

## Install

Needs macOS 14 or later, the Xcode command line tools (`xcode-select
--install`), and `jq` (`brew install jq`). `install.sh` checks all three before
it changes anything.

```bash
git clone https://github.com/mathiasthu/claude-meter
cd claude-meter
./install.sh
```

That builds the app, wires the collector into the status line, adds the two
Claude Code hooks, and loads the `com.momentumminds.claude-meter` LaunchAgent.
It is idempotent — re-run it after `git pull`.

Clone it wherever you like, but leave it there: the LaunchAgent and both hooks
point at the checkout. If you move it, re-run `./install.sh` from the new
location.

### What it changes

- `~/.claude/settings.json` — adds `statusLine` and two `hooks` entries. Both
  are appended, never assigned, so another tool's hooks survive. A `statusLine`
  you already set is left alone and the install stops with instructions rather
  than replacing it. The file is copied to `settings.json.claude-meter-bak`
  before the first change.
- `~/Library/LaunchAgents/com.momentumminds.claude-meter.plist` — starts the app
  at login.
- `~/.local/state/claude-meter/` — the snapshots.

Nothing is written outside those paths, and nothing leaves the machine.

### The status line chain

If the kickbacks ad script is installed it owns `statusLine` in settings.json
and rewrites it. Rather than fight for the slot, claude-meter uses the chain
hook kickbacks already provides: it runs whatever command is named in
`~/.kickbacks/cli-prev-statusline.json` and stacks that output on the lines
below the ad. So the install writes that file instead:

```json
{"statusLine":{"type":"command","command":"/absolute/path/to/claude-meter/bin/claude-meter-collect"}}
```

The kickbacks installer has overwritten it before, which would make the HUD
vanish silently. The `SessionStart` hook re-asserts it every session — and, on a
machine without kickbacks, re-claims `statusLine` in settings.json if it is ever
found empty.

## Reading the avatar

![Every style in every state](docs/avatar-states.png)

Four styles, switchable in Settings:

| Style | Size | For |
|---|---|---|
| **Creature · pixel** (default) | 48×48 | A blocky quadruped whose stance carries the state. Native next to a monospace prompt, and the only one that gets its laptop out and codes. |
| **Creature · blob** | 48×48 | The soft-bodied original. Same pose grammar: works, sweats, panics, sleeps. |
| **Face** | 44×44 | A companion, not an instrument. Learn the expressions once and stop reading numbers. |
| **Pill** | 128×30, grows | Maximum truth per pixel: worst metric, its number, its deadline, in one row. |

By default the state reflects `max(5h%, 7d%, worst live session context%)` — any
one of the three filling up is worth reacting to. Settings can narrow that to
the 5-hour window or context alone.

| State | Trigger |
|---|---|
| Calm | under 50% |
| Focused | 50–70% |
| Strained | 70–85% |
| Critical | 85% and up |
| Asleep | no session active in the last 5 minutes |
| Stale | data over an hour old |
| No data | rate limits have never arrived |
| Empty | no sessions at all |

The floating avatar shows the character alone by default — no plate behind it,
just a drop shadow that follows the silhouette. A plate is available in Settings
for busy wallpaper; the styles draw one either way for the `empty` state, where
a dashed outline is the entire message.

Thresholds are editable. Critical is never colour alone — each style adds a
geometric cue (badge, warning triangle, wide white eyes, ring), so escalation
survives colour-vision deficiency and greyscale.

The pixel creature moves in every state rather than only in critical: it bobs,
blinks, takes its sunglasses off on the way from calm to focused, shakes when
critical, breathes while asleep, and steps between poses in whole pixels. Every
minute or two while calm or focused it also pulls out a laptop and types for a
few seconds. Animation respects the system Reduce Motion setting — with it on,
every cycle freezes at its rest frame, state changes are instant, and the
laptop never appears.

Absence is never drawn as zero: a missing metric gets a dashed track, hollow
ring, or question-mark eyes. Stale data keeps its last value but drains to grey
and carries a clock, and countdowns are replaced by an age — a countdown implies
the number beside it is live.

**Click the avatar** for the same breakdown the menubar shows, anchored to
wherever you have parked it. Drag it to move — a press under 3 pt counts as a
click, anything more moves the window, so neither gets in the other's way.
Hover for a compact version in a tooltip.

Left-click the menubar item for the full breakdown: both account windows with
reset countdowns, then every session with its own context bar, token count, and
cost. Past four sessions the rest collapse into one row that still surfaces the
worst context fill. Right-click for show/hide avatar, reset position, Settings,
reveal snapshots, and quit.

The avatar's position is remembered, and it is placed back on screen
automatically if the display it was on goes away. With **Ignore mouse clicks**
on, clicks pass through to whatever is underneath — which also means no click
to open and no dragging; move it from the menubar's *Reset avatar position*.

## Settings

![Settings, Avatar pane](docs/settings-avatar.png)

Five panes — Avatar, State source, Thresholds, Menubar, Behaviour — with a live
preview pinned above all of them, because thresholds and the state source change
what the avatar shows and a preview you have to navigate back to is a preview
nobody uses. The sweep slider drags the selected style through the whole
escalation, and the chips force the states you cannot reach on demand: asleep,
stale, no data, empty, many sessions.

Thresholds re-order themselves rather than refusing an edit — raising Focused
past Strained pushes Strained up — and the preview strip re-colours its track to
the edited boundaries immediately.

### Reviewing it without clicking

```bash
# every style in every state, light over dark
ClaudeMeter --render-grid states.png

# the popover at none / three / ten sessions
ClaudeMeter --render-ui ui.png

# the real settings window, for a screenshot
ClaudeMeter --open-settings --settings-pane thresholds
```

The two render modes draw offscreen through `ImageRenderer`, so they need no
screen-recording permission. They cannot draw `ScrollView` content or
AppKit-backed controls, so the settings panes need the real window.

## Nothing in the menubar?

Every way this can fail looks the same from the outside — an empty menubar
item. Unwired status line, missing `jq`, Console billing, a checkout that
moved, or simply no message sent yet. So ask:

```bash
bin/claude-meter-doctor
```

It only reads. It checks `jq`, that `settings.json` parses, that the status
line names *this* checkout's collector, that both hooks are registered, that
the LaunchAgent is loaded and running, and whether the collector has ever
actually been called — then prints a fix under anything that failed and exits
non-zero.

The one that catches most people: `last-raw.json` is written on the
collector's first invocation, before it parses anything, so its absence proves
Claude Code has never called it. That is the difference between "not wired"
and "wired, nothing has happened yet", and the doctor says which.

## Uninstall

```bash
launchctl bootout "gui/$UID/com.momentumminds.claude-meter"
rm ~/Library/LaunchAgents/com.momentumminds.claude-meter.plist
rm -rf ~/.local/state/claude-meter
```

Then remove the `hooks.SessionStart` / `hooks.SessionEnd` entries from
`~/.claude/settings.json`, along with `statusLine` if it names the collector.

If you use kickbacks, restore the command claude-meter displaced rather than
deleting the file — it belongs to kickbacks, and the original is sitting next to
it:

```bash
mv ~/.kickbacks/cli-prev-statusline.json.claude-meter-bak \
   ~/.kickbacks/cli-prev-statusline.json
```

## License

Copyright © 2026 Momentum Minds LLC. All rights reserved.

Source-available, not open source. You may use, modify, and redistribute it
freely, but you **may not sell it** or include it in anything sold. See
[LICENSE](LICENSE) for the full terms.

Not affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are
trademarks of Anthropic, PBC.
