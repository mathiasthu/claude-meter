# claude-meter — handoff

## State: working, installed, running

Built 2026-08-07, visual system implemented 2026-08-08. Menubar app + floating
avatar + status line HUD, all live. `com.momentumminds.claude-meter` LaunchAgent
loaded, `RunAtLoad` + `KeepAlive`.

Verified against real payloads, not synthetic ones:

- Collector: 8 payload shapes (full, no `rate_limits`, null percentages,
  elapsed reset, 1M context, empty stdin, malformed stdin, path-unsafe
  session_id). Runs in ~50 ms against a 3 s chain deadline.
- Store, settings and styles: `scripts/selftest.sh`, 35 assertions, all pass.
- Decode: real snapshots from two concurrent sessions decode with correct
  names, percentages, token counts, costs, and reset countdowns.
- Every style in every state: rendered to `docs/avatar-states.png` and looked
  at. Two bugs were found that way and fixed — the pill's stacked-dot glyph was
  clipped, and `ScaledAvatar` force-framed every style to `naturalSize`, which
  cut off the pill (it grows with its text). `ScaledLayout` now reports the real
  intrinsic size.

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
- The floating pixel creature sits on its translucent squircle and reads over
  both a dark editor panel and wallpaper.
- Settings window: sidebar, the pinned preview strip with both appearances
  resolving differently (this was the open question — `environment(\.colorScheme:)`
  does work inside a live `NSHostingView`), sweep slider, exception chips, the
  3-column style grid, and the Thresholds pane's steppers.
- The default window height was 560 pt, which cut the Avatar pane's last two
  rows below the fold. Now 720 pt; the minimum stays at the spec's 640×520.
- `docs/settings-avatar.png` and `docs/settings-thresholds.png` are those
  screenshots.

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

## Known legibility limits without a plate

- The blob creature's calm and no-data states are the dormant grey, which
  nearly disappears on a pale wallpaper. The drop shadow is all that separates
  it. Turn the plate on, or pick a style whose resting colour is not grey — the
  pixel creature rests at brand orange.
- The pixel creature's asleep and stale states are grey for the same reason and
  have the same caveat.

## Next steps

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
./scripts/selftest.sh        # 19 headless assertions
launchctl kickstart -k gui/$UID/com.momentumminds.claude-meter   # restart the app

./dist/ClaudeMeter.app/Contents/MacOS/ClaudeMeter --render-grid /tmp/s.png  # every style, every state
./dist/ClaudeMeter.app/Contents/MacOS/ClaudeMeter --render-ui /tmp/ui.png   # popover at 0/3/10 sessions
./.build/release/ClaudeMeter --open-settings --settings-pane thresholds &   # real window, for a screenshot

echo '{...}' | bin/claude-meter-collect                    # exercise the collector
jq . ~/.local/state/claude-meter/last-raw.json             # what Claude Code last sent
ls ~/.local/state/claude-meter/sessions/                   # one file per live session
```
