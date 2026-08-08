# claude-meter — handoff

## State: working, installed, running

Built 2026-08-07; visual system, click-to-open and the plateless avatar landed
2026-08-08, followed the same day by the installer rewrite and the animated
pixel creature. Menubar item + floating avatar + settings window + status line
HUD, all live. `com.momentumminds.claude-meter` LaunchAgent loaded, `RunAtLoad`
+ `KeepAlive`, deployed from `dist/ClaudeMeter.app`.

Up to 2026-08-08 the only machine this had ever worked on was this one. The
installer rewrite below is the first work aimed at someone else being able to
run it; the rest of that list is in Next steps.

Everything is on `master` at `github.com/mathiasthu/claude-meter` (public,
source-available — see LICENSE). Deploying is `./install.sh`: it rebuilds the
bundle, re-signs it, re-asserts the status line chain, and reloads the agent.

Verified against real payloads, not synthetic ones:

- Collector: 8 payload shapes (full, no `rate_limits`, null percentages,
  elapsed reset, 1M context, empty stdin, malformed stdin, path-unsafe
  session_id). Runs in ~50 ms against a 3 s chain deadline.
- Store, settings and styles: `scripts/selftest.sh`, 36 assertions, all pass.
- Installer and hooks: `scripts/selftest-install.sh`, 30 assertions, all pass —
  against a fake `$HOME` and a fake checkout, so none of it touches this
  machine.
- Decode: real snapshots from two concurrent sessions decode with correct
  names, percentages, token counts, costs, and reset countdowns.
- Every style in every state: rendered to `docs/avatar-states.png` and looked
  at. Two bugs were found that way and fixed — the pill's stacked-dot glyph was
  clipped, and `ScaledAvatar` force-framed every style to `naturalSize`, which
  cut off the pill (it grows with its text). `ScaledLayout` now reports the real
  intrinsic size.

### What is not covered by any test

- The click-versus-drag split on the avatar. Logic-only; synthetic clicks need
  Accessibility permission this machine does not grant. `AvatarUIState.clickSlop`
  (3 pt) is the one knob if it ever mis-fires.
- Anything about how the app behaves over time — the panel surviving a display
  change, the popover under a Space switch, the LaunchAgent after a reboot.

## The installer only ever worked here

An audit of what stands between this and someone else using it came back with
one blocker that made everything else moot: `install.sh` wired the status line
only inside `if [ -d "$HOME/.kickbacks" ]`. The else branch printed a path and
moved on, nothing in the file wrote `.statusLine`, and "Done." printed either
way. Since `rate_limits` arrive through the status line and nowhere else, anyone
without that third-party plugin got a complete install, a menubar item, and no
data — permanently, silently, and indistinguishably from "no session running".

Fixed, with `scripts/selftest-install.sh` covering each case. What is worth
carrying forward:

- **Never print success you have not read back.** The install now re-reads
  `.statusLine.command` (or the chain file) and refuses to say "Done" unless it
  names this checkout's collector. Every remaining diagnostic idea in this file
  is downstream of that principle.
- **Never redirect jq at a file you care about.** `jq ... > "$SETTINGS"`
  truncates settings.json before jq runs, so a missing or failing jq left it at
  zero bytes. Temp file then `mv`, the way the collector already writes
  snapshots.
- **Append hooks, never assign them.** `.hooks.SessionStart = [...]` deleted
  whatever else was registered, and the old "already present" guard tested for
  *any* SessionEnd hook, so someone else's entry meant neither of ours was
  installed and the install said so was fine. It now strips this checkout's own
  command and re-appends, which is idempotent without being blind.
- **Resolve paths from `$0`, not `$HOME`.** The SessionStart hook hardcoded
  `$HOME/claude-meter`, so on any other checkout it hit its `[ -x ]` guard and
  exited 0 — the self-healing hook was a permanent no-op for exactly the people
  who needed it.
- **`jq` comes from `PATH`.** `/usr/bin/jq` exists on current macOS but not on
  older versions, where Homebrew's is the only one. A jq that exists but will
  not run used to be reported as "settings.json is not valid JSON".
- **`LC_ALL` beats `LC_NUMERIC`, and bash ignores `LC_ALL=C printf`.** The
  prefix form does nothing to a builtin because bash only reloads its locale on
  a real assignment, so the collector does `unset LC_ALL; export LC_NUMERIC=C`.
  Without it, cost rendered as `$0,000.00` everywhere the decimal separator is a
  comma.

The hook also re-claims an empty `.statusLine` on machines with no kickbacks, so
that path self-heals too — but only when the slot is empty. A status line
pointing somewhere else is the user's, and the installer stops with the exact
command rather than replacing it.

## Design provenance

Implemented from the Claude Design project "Avatar style selections"
(`claude-meter Visual System.dc.html`). Four styles were selected there out of
seven drafted — face, pill, pixel creature, blob creature — with the pixel
creature as the default. Colour tokens, thresholds, the 16×16 ring-with-stem
menubar mark, the five-pane settings layout and the dropdown at none / one /
three / ten sessions all come from that spec.

`docs/avatar-states.png` is the implementation's own render of the same matrix,
so it can be diffed against the spec sheet by eye.

## How the data gets here

Claude Code hands `rate_limits` and `context_window` to the **statusLine
command's stdin and nowhere else**. Confirmed by disassembling the 2.1.224
binary — the builder is `hHT(usage, size)`, and the parent object spreads
`...(R.five_hour || R.seven_day) && { rate_limits: R }`. There is no local API
to poll, no log file, no cache. If you are looking for another source, there
isn't one.

Real payload shape is kept at `~/.local/state/claude-meter/last-raw.json`,
rewritten on every status line refresh. Check it first when anything looks off.

In practice `rate_limits` contains exactly `five_hour` and `seven_day`. The
binary's internals mention `seven_day_opus`, `seven_day_sonnet`,
`seven_day_overage_included` and `overage`, but none of those have appeared in
a live payload. The collector passes the whole object through, so if they ever
show up they land in the snapshot without a code change; the app would need
updating to display them.

## The pixel creature moves

Implemented from §2 of the design handoff and `pixel-creature-anim.jsx`, which
is the pixel-exact reference. All of it lives in `PixelCreatureAvatar.swift`.

Everything is a discrete frame. One `TimelineView` drives the whole sprite,
`frame(at:)` turns the clock into a `PixelFrame`, and `PixelMotion` — `stepped`,
`toggle`, `cycle` — is the only arithmetic allowed to touch time. There is no
`withAnimation` and there must not be: an interpolated sprite stops reading as
pixel art. `HoppingLayer` is gone; critical shifts sideways instead of jumping,
which is what the spec asks for and what stops the state reading as cheerful.

**The critical shake is ±0.5 unit, not ±1.** §2's text says ±1 and the JSX
reference says ±0.5; both were rendered at the default 1.75× and compared. One
unit of total travel is a creature trembling. Two units is 10.5 pt of lateral
movement every 0.35 s, which reads as the window being dragged rather than as
panic, and puts the arms on the edge of the ground plate at each extreme. The
reference wins, which also matches the rest of §2 — the bob and the breath are
0.4 u, so sub-unit steps are already this sprite's idiom.

Two things are worth knowing before changing any of it:

- **`AvatarInput.animates` now means "reduce motion is off", nothing more.** It
  used to be `state == .critical && motionAllowed`, which was fine while
  critical was the only thing that moved. Every style already gates on
  `state == .critical` before consulting it, so the other three are unaffected;
  `MeterState.animates` was deleted rather than left lying around meaning
  something it no longer meant.
- **The pose morph needs history, so the store keeps it.** `SnapshotStore`
  records the previous state and when it changed, and hands both to the style
  through `AvatarInput`. A style cannot remember it — structs are rebuilt on
  every update, and `@State` does not compile here — and a shared mutable
  tracker would have the settings preview and the live avatar overwriting each
  other's idea of "previous". Both fields nil means "no history, draw the state
  outright", which is exactly what the preview wants while its slider sweeps
  and what `--render-grid` needs to capture a settled frame.

Two deliberate deviations, both from following the animated reference over the
prose:

- The `z` glyphs drift 6 **pt**, not 6 units. §2 says units; the reference moves
  them 6 pt, and 18 pt would slice the small `z` on the top edge of the tile
  while it is still 30% opaque.
- The falling sweat pixel is not drawn at all when motion is off. Frozen at the
  top of its fall it reads as a third sweat pixel next to the two the anatomy
  specifies, and those two are what the still frame is meant to show.

The still sheet is the check that matters: `--render-grid` output is
byte-identical to `docs/avatar-states.png` from before the change, so no state's
frozen frame moved. Motion itself was verified by rendering the creature
repeatedly over real time and measuring the sprite — bob and breath 4 px at 3×
(0.4 u), the critical shake 10 px of travel (1 u), both blinks landing, the drop
falling in five steps, the `z`s rising and fading, and every state collapsing to
exactly one frame with `motionAllowed: false`.

### What it costs, and why the schedule is not a frame rate

The first version drove this with `TimelineView(.animation(minimumInterval:
1/30))` and cost six times HEAD's idle CPU. A sprite made of step functions does
not need a frame rate: `PixelStepSchedule` yields only the instants at which
some cycle turns over, taking the minimum across whichever cycles the current
state runs, and parks when a state has none. Redraws went from ~30/s to between
2.1/s (calm) and 6.5/s (strained) — which is the spec's own step count plus the
one-a-second redraw the store's tick already forced before any of this.

Measured with a 20 s sample after an 8 s settle, alternating binaries, three
reps each, in a fixed synthetic state (`scratchpad/bench.sh`):

| state | HEAD | this | redraws/s |
|---|---|---|---|
| calm | 2.0% | 2.5% | 2.1 |
| focused | 2.0% | 3.0% | 3.3 |
| asleep | 2.2% | 4.8% | 5.3 |
| critical | 2.6% | 4.7% | 5.7 |
| strained | 2.0% | 6.7% | 6.5 |
| empty / stale / no data | 1.9% | 1.9% | 1 |

**Do not read a single measurement.** Identical work costs between 5 and 15 ms
per redraw depending on where macOS parks the process; the same strained build
measured 6.7% on an idle machine and 13.4% twenty minutes later under load,
while HEAD moved the other way. Only interleaved repetitions are comparable, and
even then the absolute numbers travel: against the real snapshot directory with
five sessions in it, asleep measured 1.2% for HEAD and 6.0% for this.

The residual is not the drawing. At the same 6.5 redraws/s, a canvas that draws
*nothing* costs 6.3% against the full sprite's 7.4% — so ~85% of every redraw is
SwiftUI updating the hosting view and flushing a transparent window, and the art
is the remaining 15%. Removing the drop shadow changes nothing measurable.
Nothing inside a style can move that number: the levers are the per-redraw cost
itself (the planned baseline work) or fewer steps than §2 asks for. Worth noting
if that trade comes up: the spec's own Interactions section says "only critical
may animate continuously", which §2 then contradicts state by state.

## Gotchas

- **`@State` does not compile on this machine.** SwiftUI's macro plugin
  (`SwiftUIMacros`) is on neither toolchain — not CommandLineTools, not
  Xcode's, and not in any SDK. `@State`, and presumably `@AppStorage` and
  `@StateObject`, are macros in the current SDK and fail with "plugin for
  module 'SwiftUIMacros' not found". `@ObservedObject` and `@Published` are
  ordinary property wrappers and still work — hence `AvatarUIState`, which
  holds what would otherwise be `@State`. Do not "simplify" it back.
  This also means the archived `whoop-data` menubar app would not build today.
- **Xcode is installed but its license has not been accepted**, so
  `DEVELOPER_DIR=/Applications/Xcode.app/... xcrun` fails. Everything builds
  fine against CommandLineTools; just do not reach for Xcode's toolchain
  expecting it to work.
- **Nothing updates while no session is running.** The status line is
  event-driven (session start, new assistant message, `/compact`, permission
  and vim mode changes). No session, no data. This is why the avatar sleeps and
  shows an age rather than freezing on a number.
- **`refreshInterval` is not available to us.** It is a field on the
  `statusLine` object in settings.json, which kickbacks owns and rewrites. The
  collector runs as a *chained* command, so it cannot ask for a timer.
- **The chain file is the single point of failure.** If
  `~/.kickbacks/cli-prev-statusline.json` disappears or stops pointing at the
  collector, the HUD vanishes and the app silently goes stale — no error
  anywhere. The `SessionStart` hook re-asserts it, and it backs up whatever it
  displaces to `.claude-meter-bak`.
- **Hooks survive kickbacks rewrites.** Observed directly: kickbacks rewrote
  `spinnerVerbs` in settings.json while the `hooks` block was untouched. It
  only claims `statusLine` and `spinnerVerbs`.
- **Screen recording works again after a reboot** (it was denied before, and
  `screencapture` failed with "could not create image from display"). If it
  breaks again, `--render-grid` and `--render-ui` render offscreen through
  `ImageRenderer` and need no permission.
- **`ImageRenderer` cannot draw everything.** `ScrollView` and `LazyVGrid`
  content comes out blank, and AppKit-backed controls (`Slider`, `Stepper`,
  `.buttonStyle(.link)`) render as a placeholder block. So `--render-ui` is
  trustworthy for the popover and useless for the settings panes — use
  `--open-settings` and a real screenshot for those.
- **A status item cannot be clicked programmatically** without Accessibility
  permission, which `osascript` does not have here ("osascript is not allowed
  assistive access"). Hence `--open-settings [--settings-pane <name>]`, which
  opens the window at launch. It also flips the activation policy to `.regular`,
  because an `.accessory` app launched from a background shell cannot raise a
  window above the frontmost app. Run it as a second instance, screenshot, kill
  it — it adds a second menubar item for those few seconds.
- **`@State`'s absence spreads.** `@AppStorage` and `@StateObject` are macros in
  the same plugin, so neither is available either. `SettingsStore` is a plain
  `ObservableObject` over `UserDefaults`, and every view-local piece of state
  (`AvatarUIState`, `SettingsUIState`) is an `ObservableObject` owned by the
  enclosing AppKit object.
- **`scaleEffect` does not resize the layout box.** Combined with a fixed
  `.frame(naturalSize)` it silently clips any style that grows. `ScaledLayout`
  measures the subview and claims `intrinsic × scale`; keep new styles going
  through `ScaledAvatar` rather than framing them by hand.
- **Launch-at-login is deliberately inert when the LaunchAgent exists.**
  install.sh already starts the app at login; also registering `SMAppService`
  would double-launch it. The Behaviour pane detects the plist and shows the
  toggle on and disabled with an explanation.

## Verified on screen

Screenshotted live on 2026-08-08, after screen recording came back:

- Menubar mark renders with its stem, arc clockwise from the top, text
  "5h 8% · 4h51m". Calm's arc is deliberately low-contrast.
- The floating pixel creature reads over both a dark editor panel and wallpaper.
  (That screenshot predates the plate coming off; it now renders bare with a
  drop shadow, re-checked at 1.75× and still legible over both.)
- Settings window: sidebar, the pinned preview strip with both appearances
  resolving differently (this was the open question — `environment(\.colorScheme:)`
  does work inside a live `NSHostingView`), sweep slider, exception chips, the
  3-column style grid, and the Thresholds pane's steppers.
- The avatar's popover, opened through the real `.accessory` path: account
  windows with countdowns, four session rows, the overflow row, and the footer.
- The default window height was 560 pt, which cut the Avatar pane's last two
  rows below the fold. Now 720 pt; the minimum stays at the spec's 640×520.
- `docs/settings-avatar.png` is that screenshot, refreshed after the plate came
  off and the Background plate row was added.

## Fixed after looking at it on screen

- **The plate read as a card with a picture in it**, not as a character. It is
  off by default now (`Background plate` in Settings), replaced by a drop
  shadow that follows the silhouette. `empty` keeps its dashed outline in both
  modes, since without it that state would draw nothing at all.
- **Default scale was 1x**, which is 48 pt of pixel art — too small to read at a
  glance. Now 1.75x, and the slider reaches 4x instead of 2x.
- **`NSScreen.main` is nil for an agent app with no key window.**
  `moveToDefaultCorner()` guarded on it and so silently did nothing, leaving the
  panel at the origin — off the bottom-left corner, unreachable. It only
  surfaced when the bigger avatar made a stored origin fail its on-screen check
  and fall through to that path. Now falls back to `NSScreen.screens.first`, and
  `resizeToFit()` clamps the frame back on screen after growing.

## Clicking the avatar

Opens the same `SessionListView` the menubar does, in a second `NSPopover`
anchored to the panel's content view.

Two things make this less obvious than it sounds:

- **The app has to be activated first.** The avatar lives in a
  `.nonactivatingPanel`, so clicking it does not make the app active, and a
  `.transient` popover owned by an inactive app dismisses itself immediately.
  `toggleAvatarPopover()` calls `NSApp.activate(ignoringOtherApps:)` — fine
  here because it is an explicit click, unlike merely showing the avatar.
- **Click and drag share the press.** `isMovableByWindowBackground` is off
  because it swallows the press before a click could be recognised. A
  `DragGesture(minimumDistance: 0)` tracks `NSEvent.mouseLocation` in screen
  coordinates — not the gesture's own translation, which fights itself once the
  window starts moving under the cursor — and accumulates distance. Under 3 pt
  on release is a click; past that it moves the window and suppresses the click.

Verified with `--open-avatar-popover`, which opens it at launch without
promoting the activation policy, so it exercises the real `.accessory` path.
The click/drag split itself is logic-only — it has not been driven with a real
mouse, because synthetic clicks need Accessibility permission this machine does
not grant.

## This machine has two displays — mind that when screenshotting

`screencapture -x out.png` captures the **main display only**. Here that is the
4096×2304 external; the built-in Liquid Retina XDR is a second screen sitting
below it in the global coordinate space (`158 -1169 1800 1130`). Negative y in a
saved window frame means the built-in, not "off-screen".

This cost real time: the settings window kept appearing to open and do nothing,
and it was diagnosed as a stale autosaved frame pointing at a disconnected
display. It was not — the window was on the built-in the whole time, and the
capture simply did not cover it. Use `screencapture -x -D 2 out.png` for the
second display, and check `system_profiler SPDisplaysDataType` before concluding
a window is lost.

`SettingsWindowController.recoverIfOffscreen()` was added during that wrong
diagnosis. It is kept because it is a genuine safeguard —
`setFrameAutosaveName` does restore a frame verbatim without checking the
screen still exists, so a real unplug would strand the window — but it is
guarding a case that has not actually been observed.

## Known legibility limits without a plate

- The blob creature's calm and no-data states are the dormant grey, which
  nearly disappears on a pale wallpaper. The drop shadow is all that separates
  it. Turn the plate on, or pick a style whose resting colour is not grey — the
  pixel creature rests at brand orange.
- The pixel creature's asleep and stale states are grey for the same reason and
  have the same caveat.

## Next steps

The audit that produced the installer fixes above ranked the rest of it. In
order, because each one unblocks the next:

- **Make failure legible.** Every failure mode still renders as an empty
  menubar item: unwired status line, missing jq, Console billing, no session
  open, moved checkout. A `bin/claude-meter-doctor` that checks each of those
  and prints pass/fail is the single highest-value thing left. `last-raw.json`
  is written before any parsing, so its absence proves the collector has never
  run — which is the one signal that distinguishes "not connected" from "idle",
  and `SnapshotStore.state` currently returns `.empty` for both.
- **Pay back the idle CPU.** Baseline is ~1.8% of a core before the creature
  moves and 2.5–6.7% after, against a target of 0.5%. Three known causes, none
  of them the avatar: `.id(store.tick...)` at `SessionListView.swift:31` tears
  down and rebuilds a 296 pt view tree every second; `refreshStatusItem()`
  rebuilds an `NSImage` and an attributed title every second for strings that
  change once a minute; and `popover.contentViewController` is never cleared on
  close, so both hosting controllers keep rebuilding invisibly — that last one
  is the permanent step from ~1.7% to ~4.6% after the first popover open.
- **Treat an elapsed rate-limit window as reset.** `SnapshotStore` reads the
  percentage off the newest snapshot with no expiry check, so hours after a
  window provably emptied the app still shows its last value in grey. Every
  snapshot already carries `resets_at`; the only place it meets `now` is
  `Format.swift:37-40`, where it merely suppresses a countdown. Best
  value-per-hour item on this list — no new data, no new storage, and it turns
  the moment the tool is least useful into the moment it is most useful.
- **Keep one line of history.** A `{ts, five_hour_pct, resets_at}` append to a
  `history.jsonl` after the snapshot write, trimmed by the same sweep, is the
  entire data dependency for burn rate and for "will this run die halfway" —
  the question the current architecture structurally cannot answer, because
  `SessionEnd` and the 24 h sweep mean nothing is ever retained.
- Decide whether the pixel creature sits too high in its ground. Content spans
  y 6–31.5 in a 48 pt box, so there is 6 pt above and 16.5 pt below. It is
  faithful to the spec's coordinates, which is why it was left alone; shifting
  it down ~5 pt would centre it.
- Calm and focused are hard to tell apart on the pixel creature at 1× — the
  sunglasses bar and the two eye squares occupy nearly the same footprint. It
  reads correctly when enlarged. Worth a wider or differently-shaped visor if
  it turns out to matter in use.
- The 24 h snapshot sweep in the collector is the only cleanup for sessions
  that die without firing `SessionEnd` (a `kill -9`, a crashed terminal). If
  ghost sessions linger in the popover, shorten `MAX_AGE_MIN`.
- Menubar text is fixed to the 5-hour window. If the 7-day window is the one
  that actually bites, switch `refreshTitle()` in `MenubarController.swift`.
- No notification when a threshold is crossed — the avatar just changes face.
  `UNUserNotificationCenter` at 85% would need a signed bundle to be reliable.

## Commands

```bash
./install.sh                 # build + wire + load. idempotent.
./scripts/build-app.sh       # rebuild the bundle only
./scripts/selftest.sh        # 36 headless assertions: store, settings, styles
./scripts/selftest-install.sh # 30 assertions: installer + hooks, fake $HOME
launchctl kickstart -k gui/$UID/com.momentumminds.claude-meter   # restart the app

./dist/ClaudeMeter.app/Contents/MacOS/ClaudeMeter --render-grid /tmp/s.png  # every style, every state
./dist/ClaudeMeter.app/Contents/MacOS/ClaudeMeter --render-ui /tmp/ui.png   # popover at 0/3/10 sessions
./.build/release/ClaudeMeter --open-settings --settings-pane thresholds &   # real window, for a screenshot
./.build/release/ClaudeMeter --open-avatar-popover &                       # avatar's popover, real .accessory path

echo '{...}' | bin/claude-meter-collect                    # exercise the collector
jq . ~/.local/state/claude-meter/last-raw.json             # what Claude Code last sent
ls ~/.local/state/claude-meter/sessions/                   # one file per live session
```
