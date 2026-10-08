# CLAUDE.md

## Project notes (moved from ~/CLAUDE.md on 2026-10-08)

Swift + Bash. Claude Code usage HUD: menubar app `ClaudeMeter.app` + floating avatar, launchd `com.momentumminds.claude-meter`. No port. `rate_limits` (5h/7d) and `context_window` reach the machine **only** via the statusLine command's stdin; there is no API to poll. `bin/claude-meter-collect` publishes snapshots to `~/.local/state/claude-meter/`; the app reads those. Chains off kickbacks via `~/.kickbacks/cli-prev-statusline.json` (never touches `statusLine` in settings.json); a `SessionStart` hook re-asserts that file, `SessionEnd` deletes the closed session's snapshot. `@State` won't compile here (SwiftUI macro plugin missing on every toolchain); use `@ObservedObject`.
