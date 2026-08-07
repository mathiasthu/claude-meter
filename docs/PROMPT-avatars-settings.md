# Design brief: claude-meter avatars, settings, and menubar item

Self-contained. Paste everything below the line into a design agent — it needs
no repository access, and every fact it requires is stated here.

---

Design the visual system for a macOS utility called **claude-meter**. You are
designing, not implementing: deliver specs and mockups precise enough that an
engineer can build from them without asking follow-up questions.

## What the product is

Claude Code is a terminal coding tool with usage limits. Its users hit two
walls, and today they can only see either one by typing a command or opening a
website:

- **Account rate limits** — a rolling 5-hour window and a rolling 7-day window,
  each reported as a percentage consumed plus the time it resets.
- **Per-session context fill** — each open session has a context window that
  fills as the conversation grows. At 100% the session stops being useful and
  has to be compacted.

claude-meter surfaces both, continuously, without the user asking. It lives in
the macOS menubar with an optional floating widget on top of other windows. The
person using it is a developer who already has a full screen of terminals and
editors. They are not looking at this widget; they need it to catch their eye
only when something is about to bite, and to be ignorable the rest of the time.

## The data you have to work with

Exactly this, nothing more:

| Value | Range / notes |
|---|---|
| 5-hour window used | 0–100%. **Can be entirely absent.** |
| 5-hour window resets at | A timestamp. Render as a countdown, e.g. "3h07m", "46m". |
| 7-day window used | 0–100%. Can be absent independently. |
| 7-day window resets at | Same, but often days away. |
| Per-session context used | 0–100%. **Can be null** even when the session is active. |
| Per-session tokens | e.g. 247,000 of 200,000 or 1,000,000 capacity. |
| Per-session cost | US dollars, e.g. $11.75. Can reach three figures. |
| Per-session name | Free text, can be long: "Phase 3 member area and public site rebuild". Can be absent, in which case a directory name is used. |
| Model name | e.g. "Opus 5 (1M context)". Long. |
| Snapshot age | Seconds since this data was last refreshed. |
| Session count | **0, 1, or many.** Two or three concurrent sessions is normal. |

Two things about absence, because they drive real design decisions:

- **Absent is not zero.** Rate limits are missing for users on pay-as-you-go
  billing, and missing in any session until its first response arrives. A design
  that renders missing data as an empty 0% bar tells the user the opposite of
  the truth. Missing needs its own visual treatment.
- **Data goes stale silently.** The app only receives updates while a session is
  actively working. With no session running, nothing arrives — so the numbers on
  screen may be minutes or hours old. The design must distinguish "current" from
  "last seen 40 minutes ago" without the user having to think about it.

## States every design must handle

Six escalating states plus three exceptions. The escalation is driven by the
worst of (5-hour %, 7-day %, fullest active session's context %):

| State | Trigger |
|---|---|
| Calm | under 50% |
| Focused | 50–70% |
| Strained | 70–85% |
| Critical | 85% and up |
| Asleep | no session active in the last 5 minutes |
| Stale | data older than an hour |
| No data | no rate limits have ever arrived |
| Empty | no sessions at all |
| Many | 3+ concurrent sessions, each with different context fill |

The thresholds above are the current defaults and will become user-editable, so
do not design anything that only reads correctly at exactly 50/70/85.

## Deliverable 1 — six floating avatar styles

The floating widget sits on top of everything, on any Space, and is dragged
wherever the user wants it. It never takes keyboard focus.

Design **six visually distinct styles** the user can switch between. The point
of six is genuine range — someone who wants a character and someone who wants a
2mm dot should both be satisfied. Directions, not a specification; propose
better ones if you have them:

1. **Face** — an expressive character whose expression carries the state. The
   existing version uses text emoticons (`◕‿◕`, `◉益◉`); design something with
   more craft than that.
2. **Rings** — concentric arcs, one metric per ring, readable from across a room.
3. **Pill** — wide and low, maximum information density in one row.
4. **Dot** — the minimum that still communicates. Nearly invisible when calm.
5. **Creature** — a small character with poses rather than just expressions:
   idle, working, straining, panicking, sleeping.
6. **Gauge** — analogue. A needle, a dial, a fuel gauge.

For each style specify: exact pixel dimensions at 1× (and how it scales),
internal spacing, type sizes and weights, the full colour ramp across all six
escalation states, and what each of the three exception states looks like.

Constraints: it sits over unpredictable backgrounds, so it needs its own ground
— translucent material, a solid fill, or a strong outline. It must read in both
light and dark system appearance. Only the critical state may animate, and that
animation must have a still fallback for users who have asked the system to
reduce motion. Assume 1× and 2× displays.

## Deliverable 2 — a settings window

There is no settings surface today. Design a resizable macOS window, native in
feel, covering:

- **Avatar**: which style, scale, opacity, show/hide, whether it ignores clicks
  entirely, whether it floats over full-screen apps.
- **What drives the state**: the worst of all three metrics, or the 5-hour
  window alone, or context alone. Different people are limited by different
  things.
- **Thresholds**: the four boundaries, editable, kept in order, 0–100.
- **Menubar**: which metric is shown, text vs. icon vs. both, whether the reset
  countdown is included.
- **Behaviour**: launch at login, reduce-motion override, reset to defaults.

The window needs a **live preview** of the selected avatar with a control that
sweeps it through every state — choosing a style must not mean guessing. Show
how the preview is laid out relative to the controls, and how the settings are
grouped and ordered. Assume the list of styles will grow, so the picker must
survive twelve entries as gracefully as six.

## Deliverable 3 — the menubar item

The macOS menubar gives you roughly 22pt of height and as little width as you
can manage. Design:

- The **compact icon**: a ring, bar, or mark that encodes the current state and
  percentage legibly at that size, in both light and dark menubars. It must not
  read as a system icon.
- The **text variants**: which metric, with and without a countdown, and how
  they degrade when data is missing.
- The **dropdown panel** shown on click: both account windows with their reset
  countdowns, then one row per session with its context bar, tokens, cost, and
  age. Design it for one session, for three, and for none — and decide what
  happens at ten. Session and model names are long enough to need a truncation
  strategy.

## Anti-goals

- Nothing that demands attention when everything is fine. Calm should be close
  to invisible.
- No fake precision — no decimal places on a percentage, no second-by-second
  countdown.
- Nothing that misrepresents missing or stale data as current or as zero.
- No dependence on colour alone to signal the critical state; roughly 8% of men
  have some form of colour-vision deficiency, and this is a developer tool.

## What to hand back

For each of the three deliverables:

1. A short statement of intent — what this style or screen is *for*, and who
   picks it.
2. Exact specs: dimensions, spacing, type scale, colour values as named tokens
   (not raw hex scattered through prose), and motion timing where relevant.
3. A **self-contained HTML or SVG mockup sheet** rendering every state side by
   side, in both light and dark appearance, so the whole system can be compared
   at once. No external assets, fonts, or scripts — it must open standalone.
4. A one-paragraph rationale for anything non-obvious, especially how you chose
   to represent missing and stale data.

Start by proposing the six avatar directions in one or two sentences each and
asking which to develop, rather than fully rendering all six unprompted.
