# Prompt: avatar styles, settings, and menubar work

Paste everything below the line into Claude Code, run from the `claude-meter`
repo root.

---

Read `README.md` and `HANDOFF.md` first — they explain where the data comes
from and which constraints are load-bearing. Then build three things.

## What this app is

`claude-meter` shows Claude Code usage without opening claude.ai. A bash
collector runs as a Claude Code statusLine command, publishes one JSON snapshot
per session to `~/.local/state/claude-meter/sessions/<session_id>.json`, and a
Swift menubar agent reads those. `SnapshotStore` watches that directory and
republishes; `Mood` maps percentages to a state; `AvatarFace` draws the
floating card; `MenubarController` owns the status item, the popover, and the
panel.

The single source of truth for what a real payload looks like is
`~/.local/state/claude-meter/last-raw.json`. Read it before you assume a field
exists.

## Deliverable 1 — a pluggable avatar style system

Today there is exactly one avatar: an emoticon face in a rounded card. Replace
that with an abstraction where adding a style is one new file, not an edit to
five.

Design an `AvatarStyle` protocol (or equivalent) that takes a rendering input —
mood, 5h percent, 7d percent, worst live context percent, session count,
staleness, whether animation is permitted — and returns a SwiftUI view. Register
styles in one place so the settings picker and the panel both enumerate the
same list.

Then implement at least **six** distinct styles. These are directions, not a
spec — design them properly, and propose better ones if you have them:

1. **Face** — the current emoticon card, ported to the new protocol unchanged so
   there is a known-good baseline.
2. **Rings** — concentric arcs, outer for the 5-hour window, inner for context,
   percentage in the middle. Glanceable from across a room.
3. **Pill** — a wide, low, translucent bar: two small meters and their numbers
   in one row. The most information per pixel.
4. **Dot** — the minimum that still communicates: one colour-filled dot and a
   number. For someone who wants it nearly invisible.
5. **Creature** — a small pixel/sprite character with per-mood poses. Give it
   more personality than the emoticons: idle, working, strained, panicking,
   sleeping.
6. **Gauge** — an analogue dial or fuel-gauge needle sweeping from calm to
   alarmed.

Every style must handle the states that are not a percentage: **asleep** (no
session active in the last 5 minutes), **stale** (data older than an hour), and
**no data at all** (`rate_limits` absent — the user is not on a Claude.ai
subscription, or no API response has come back yet). A style that renders these
as "0%" is wrong: 0% and "unknown" mean opposite things here.

Each style declares its own natural size, and the panel resizes to fit when the
style changes.

## Deliverable 2 — settings

There is no settings surface at all right now; preferences are two ad-hoc
`UserDefaults` keys read inline. Build a real one.

A `SettingsStore: ObservableObject` owning every preference, persisted to
`UserDefaults`, with a documented default for each and a "reset to defaults"
action. Inject it where it is needed — do not read `UserDefaults` from views.

A settings window (`NSWindow`, not a popover — it should be resizable and stay
open while the user experiments) reachable from both the menubar right-click
menu and the popover footer. It needs a **live preview** of the selected avatar
style driven by a fake snapshot the user can scrub through the mood range, so
choosing a style does not mean guessing.

Cover at least:

- **Avatar**: style, scale, opacity, show/hide, click-through (ignore mouse
  events entirely), and whether it floats above full-screen apps.
- **What drives the mood**: `max(5h, 7d, context)` as now, or 5h only, or
  context only. Different people are throttled by different things.
- **Thresholds**: the four boundaries, editable, with validation that keeps them
  ordered and inside 0–100.
- **Menubar**: which metric the title shows, text vs. a compact rendered icon vs.
  both, and whether the reset countdown is included.
- **Behaviour**: launch at login, and an override for reduce-motion.

Thresholds live in `Mood.swift` today **and are duplicated in the bash collector's
HUD colouring** (`bin/claude-meter-collect`). If the user can edit them, the two
must not drift — either have the app write a small config file the collector
reads, or make the collector read the same `UserDefaults` domain via `defaults
read`. Pick one and say why.

## Deliverable 3 — the menubar item

Currently a fixed text title showing the 5-hour window.

- Honour the settings above: chosen metric, text/icon/both, optional countdown.
- Build the compact icon variant — a small ring or bar rendered to an `NSImage`
  that reads correctly in both light and dark menubars, and stays legible at
  menubar height.
- Add "Settings…" to the right-click menu and the popover footer.
- Keep the existing left-click popover and right-click menu split.

## Constraints that will cost you hours if you skip them

- **`@State`, `@StateObject`, and `@AppStorage` do not compile on this machine.**
  SwiftUI's macro plugin (`SwiftUIMacros`) is absent from every toolchain and
  SDK here, and those are macros in the current SDK. `@ObservedObject` and
  `@Published` are ordinary property wrappers and work fine. The existing
  `AvatarUIState` in `AvatarFace.swift` shows the pattern: hold view-local state
  in an `ObservableObject` owned by the enclosing AppKit object. Follow it. Do
  not "fix" it back to `@State`.
- **Never touch `statusLine` in `~/.claude/settings.json`.** It belongs to the
  kickbacks ad script, which rewrites it. claude-meter chains off
  `~/.kickbacks/cli-prev-statusline.json` instead. Breaking this silently kills
  the entire data feed with no error anywhere.
- **The avatar panel must never take focus.** It is a `.nonactivatingPanel`,
  `canBecomeKey` is `false`, and it is shown with `orderFrontRegardless()`. The
  settings window is the opposite and *does* need focus — because the app is
  `.accessory`, opening it requires `NSApp.activate(ignoringOtherApps: true)` or
  it will appear behind everything.
- **Every numeric field is optional.** `rate_limits` is absent for non-subscribers
  and before a session's first API response; `context.usedPercentage` is null
  early in a session and again right after `/compact`. Force-unwrapping any of
  them will crash on a real machine within the hour.
- **Respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`** in every
  animated style, unless the user has overridden it in settings.
- **No new dependencies.** AppKit, SwiftUI, Foundation, Combine only.

## Definition of done

- `./scripts/selftest.sh` still passes, extended with cases for the new settings
  store — persistence round-trip, threshold validation rejecting out-of-order
  values, and defaults on a clean domain.
- `./scripts/build-app.sh` builds with no warnings.
- Every avatar style renders in all six mood states plus the no-data state.
  Prove it: add a preview/debug mode that renders the full grid, since these are
  states you cannot reach on demand from real data.
- Switching style, scale, opacity, or threshold updates the avatar and menubar
  **without a restart**.
- Settings survive a relaunch (`launchctl kickstart -k
  gui/$UID/com.momentumminds.claude-meter`).
- `HANDOFF.md` updated: what changed, and any new gotcha you hit.

## Verifying, given you cannot screenshot

Screen recording is denied to the terminal on this machine, so `screencapture`
fails with "could not create image from display". Do not burn time on it. Verify
with headless tests over the store and the settings model, exercise the state
machine by writing crafted snapshot files into
`~/.local/state/claude-meter/sessions/`, and then **ask the user to look at the
result** and describe what they see. Do not claim the UI looks right — you
cannot see it.
