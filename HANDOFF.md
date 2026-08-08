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
- **Screen recording is denied to the terminal**, so `screencapture` fails with
  "could not create image from display". Do not burn time on it. Use
  `--render-grid` instead: `ImageRenderer` draws offscreen and needs no
  permission, which is how the avatars actually got reviewed. What it cannot
  show is the live window — panel placement, the settings window's real
  controls, and anything about how it behaves on screen are still unverified.
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

## Next steps

- Look at the running app: panel placement and size, the settings window's
  layout, and whether the default (pixel creature at 100%) is the right one.
  `docs/avatar-states.png` covers the art; none of the live behaviour is covered.
- The preview strip forces light and dark with `environment(\.colorScheme:)`.
  That resolves the dynamic `NSColor` tokens correctly in the offscreen render;
  whether it also does inside a live `NSHostingView` is unconfirmed. If both
  halves look identical, that is why — the fix is an explicit `NSAppearance` on
  a hosting view per half.
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

./dist/ClaudeMeter.app/Contents/MacOS/ClaudeMeter --render-grid /tmp/s.png  # review every state

echo '{...}' | bin/claude-meter-collect                    # exercise the collector
jq . ~/.local/state/claude-meter/last-raw.json             # what Claude Code last sent
ls ~/.local/state/claude-meter/sessions/                   # one file per live session
```
