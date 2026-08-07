# claude-meter

See your Claude Code 5-hour limit, weekly limit, and per-session context fill
without opening claude.ai.

A menubar item plus a floating avatar, fed by a collector that hangs off Claude
Code's status line.

```
menubar:   5h 41%

avatar:    ╭───────╮
           │  ◕‿◕  │   5h  41%
           ╰───────╯   ctx 22%

status line (below the kickbacks ad):
           5h 41% ·3h07m   7d 15%   ctx 22% 225k/1M   $8.34
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
  current.
- **`rate_limits` needs a Claude.ai subscription and one API response.** It is
  absent for Console billing, and absent in a brand new session until the first
  reply comes back. The UI shows "no limit data yet" rather than 0%.

For an authoritative on-demand check inside a session, `/usage` (alias `/cost`)
and `/context` are built in.

## Layout

| Path | What it does |
|---|---|
| `bin/claude-meter-collect` | Status line command. Publishes a snapshot per session and prints the HUD line. |
| `bin/claude-meter-session-end` | `SessionEnd` hook. Deletes the snapshot so the avatar knows the session closed. |
| `bin/claude-meter-session-start` | `SessionStart` hook. Re-asserts the status line chain if something clobbered it. |
| `Sources/ClaudeMeter/` | The menubar app and floating avatar. |
| `scripts/build-app.sh` | Builds `dist/ClaudeMeter.app`. |
| `scripts/selftest.sh` | Headless tests for the store, moods, liveness, and malformed input. |
| `install.sh` | Does all of the wiring below. Idempotent. |

Snapshots live outside the repo, in `~/.local/state/claude-meter/`:

- `sessions/<session_id>.json` — one per session, rewritten on every status line refresh
- `last-raw.json` — the most recent raw status line payload, kept for debugging schema changes

## Install

```bash
./install.sh
```

That builds the app, chains the collector into the status line, adds the two
Claude Code hooks, and loads the `com.mathias.claude-meter` LaunchAgent.

### The status line chain

`~/.claude/settings.json`'s `statusLine` belongs to the kickbacks ad script,
which rewrites it. Rather than fight that, claude-meter uses the chain hook
kickbacks already provides: it runs whatever command is named in
`~/.kickbacks/cli-prev-statusline.json` and stacks that output on the lines
below the ad. So the install writes:

```json
{"statusLine":{"type":"command","command":"/Users/mathiass/claude-meter/bin/claude-meter-collect"}}
```

The kickbacks installer has overwritten that file before, which would make the
HUD vanish silently. The `SessionStart` hook re-asserts it every session.

Without kickbacks, point `statusLine.command` straight at
`bin/claude-meter-collect` instead.

## Reading the avatar

The face reflects `max(5h%, 7d%, worst live session context%)` — any one of the
three filling up is worth reacting to.

| Face | State | Trigger |
|---|---|---|
| `◕‿◕` | calm | under 50% |
| `◔_◔` | focused | 50–70% |
| `◕﹏◕` | sweating | 70–85% |
| `◉益◉` | alarmed (pulses) | 85% and up |
| `-_-` | asleep | no session active in the last 5 minutes |
| `?_?` | stale | live sessions but no usable numbers, or data over an hour old |

The pulse respects the system Reduce Motion setting.

Left-click the menubar item for the full breakdown: both account windows with
reset countdowns, then every session with its own context bar, token count, and
cost. Right-click for show/hide avatar, reset avatar position, reveal snapshots,
and quit.

Drag the avatar anywhere; its position is remembered, and it is placed back on
screen automatically if the display it was on goes away.

## Uninstall

```bash
launchctl bootout "gui/$UID/com.mathias.claude-meter"
rm ~/Library/LaunchAgents/com.mathias.claude-meter.plist
rm ~/.kickbacks/cli-prev-statusline.json     # drops the HUD line
rm -rf ~/.local/state/claude-meter
```

Then remove the `hooks.SessionStart` / `hooks.SessionEnd` entries from
`~/.claude/settings.json`.
