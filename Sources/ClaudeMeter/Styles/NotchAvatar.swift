import SwiftUI

/// One of the three readings on the strip, resolved once for both the ring and
/// the row that describes it in the popover.
///
/// The two are built from the same array on purpose: a ring and its row can
/// then never disagree about whether a number exists, which is the failure this
/// design is most exposed to — three rings and a popover all deriving "do we
/// have a 7-day reading?" separately.
struct NotchReading {
    let ring: NotchRing
    /// "5-hour window", "7-day window", or the session's own name.
    let title: String
    let tag: String
    /// Nil is drawn dashed and labelled with an em-dash. Never 0.
    let pct: Double?
    /// The line under the row: a countdown, a reset, or what the context ring
    /// is actually looking at.
    let sub: String

    var known: Bool { pct != nil }

    /// Spoken form. Built from the same reading the ring draws, so the two
    /// cannot drift — the pattern `MenubarIcon.accessibilityLabel` sets
    /// (`MenubarIcon.swift:123-126`).
    var accessibilityLabel: String {
        guard let pct else { return "\(title), no reading" }
        return "\(title), \(Int(pct.rounded())) percent used"
    }
}

/// Turns one `AvatarInput` into the three readings the strip and its popover
/// both draw. Pure, and the only place the no-data rules for the notch live.
enum NotchData {

    /// Asleep and stale both mean "these numbers are not current". The strip
    /// dims to 0.55 and every ring goes dashed, matching what the dropdown does
    /// to the same data (`SessionListView.swift:54`).
    static func isDormant(_ input: AvatarInput) -> Bool {
        input.state == .stale || input.state == .asleep
    }

    static func readings(_ input: AvatarInput) -> [NotchReading] {
        let dormant = isDormant(input)
        let age = input.age
        return [
            NotchReading(
                ring: .fiveHour, title: "5-hour window", tag: NotchRing.fiveHour.tag,
                pct: dormant ? nil : input.fiveHour,
                sub: windowSub(pct: input.fiveHour, resetsAt: input.fiveHourResetsAt,
                               hasReset: input.fiveHourHasReset, age: age, dormant: dormant)),
            NotchReading(
                ring: .sevenDay, title: "7-day window", tag: NotchRing.sevenDay.tag,
                pct: dormant ? nil : input.sevenDay,
                sub: windowSub(pct: input.sevenDay, resetsAt: input.sevenDayResetsAt,
                               hasReset: input.sevenDayHasReset, age: age, dormant: dormant)),
            NotchReading(
                ring: .context, title: input.contextName ?? "Session context",
                tag: NotchRing.context.tag,
                pct: dormant ? nil : input.context,
                sub: contextSub(input)),
        ]
    }

    /// The ramp, and the only colour decision in the notch. `ramp` already
    /// answers `nil` with the dormant grey, so an unknown reading needs no
    /// branch of its own here.
    static func color(_ r: NotchReading, _ t: Thresholds) -> Color {
        AvatarInput.ramp(r.pct, t)
    }

    private static func windowSub(pct: Double?, resetsAt: Double?, hasReset: Bool,
                                  age: TimeInterval?, dormant: Bool) -> String {
        // Checked before staleness for the reason `SessionListView.trailing`
        // checks it first: a window past its reset is empty *now*, so the zero
        // is the one number on the strip that is definitely current even when
        // the snapshot it came from is hours old. It gets the moment it
        // emptied, never a countdown to a time that has already passed.
        if hasReset {
            guard let at = resetsAt else { return "window has reset" }
            return "reset \(Fmt.age(Date().timeIntervalSince1970 - at)) ago"
        }
        // A countdown beside a dashed ring would claim the window is still
        // being watched when the readings behind it have gone cold.
        if dormant {
            return age.map { "last seen \(Fmt.age($0)) ago" } ?? "no reading yet"
        }
        guard pct != nil else { return "no reading yet" }
        // A reading with no `resets_at` beside it. The window is genuinely at
        // this percentage and genuinely has no deadline attached — a partial
        // rate_limits payload — so the sub-line says which half is missing
        // rather than "no reading yet", which would contradict the live arc
        // and the percentage printed directly above it.
        guard let reset = Fmt.countdown(to: resetsAt, spaced: true)
        else { return "no reset time" }
        return "resets in \(reset)"
    }

    /// Context has no reset, so its sub-line says what the reading is *of* —
    /// which session, on which model, and how far behind the numbers are.
    private static func contextSub(_ input: AvatarInput) -> String {
        guard input.contextName != nil else { return "no live session" }
        let head = "\(input.contextModel ?? "—") · "
            + Fmt.tokenPair(input.contextTokens, input.contextSize)
        // This session's own age, not the newest one across all of them. The
        // row is describing one session, and printing the app's freshest
        // timestamp beside it reads as "this 90% is ten seconds old" at the
        // one moment that is least true — see `AvatarInput.contextAge`.
        guard let age = input.contextAge else { return head }
        return "\(head) · \(Fmt.age(age)) ago"
    }
}

/// 05 · Side notch — 76 × 344 pt, docked flush against a screen edge.
///
/// The one style that is an instrument rather than a character: it shows all
/// three readings at once and never animates. Display-only, and deliberately
/// so — the thumbnail, the settings preview and the state sheet all render this
/// same view, and the tap targets that make it interactive are composed over it
/// one layer up where there is an object that can remember what was clicked.
struct NotchStrip: View {
    let input: AvatarInput
    /// The user's scale, applied to this style's metrics rather than to its
    /// rendered output — the same trade `PillAvatar` makes, and for the same
    /// reason (`PillAvatar.swift:14-19`). Everything below is a multiple of it.
    var scale: CGFloat = 1

    private var s: CGFloat { scale }

    var body: some View {
        ZStack(alignment: .topLeading) {
            NotchShape(edge: input.notchEdge)
                .fill(LinearGradient(colors: [Tokens.notchTopC, Tokens.notchBottomC],
                                     startPoint: .top, endPoint: .bottom))
            NotchShape(edge: input.notchEdge)
                .stroke(Tokens.notchHairlineC, lineWidth: 1 * s)

            // Placed by absolute offset rather than by centring a VStack: the
            // panel reproduces this column from `NotchMetrics` alone to aim the
            // popover's arrow at a ring, and a centring pass is not something
            // arithmetic elsewhere can reproduce.
            ForEach(Array(NotchData.readings(input).enumerated()), id: \.offset) { i, r in
                NotchRingView(reading: r,
                              color: NotchData.color(r, input.thresholds),
                              selected: input.selectedRing == r.ring,
                              scale: s)
                    .frame(width: NotchMetrics.width(scale: s),
                           height: NotchMetrics.itemHeight(scale: s))
                    .offset(y: NotchMetrics.itemTop(i, scale: s))
            }
        }
        .frame(width: NotchMetrics.width(scale: s), height: NotchMetrics.height(scale: s))
        .opacity(NotchData.isDormant(input) ? 0.55 : 1)
        // Pinned dark, unlike every other style. The strip is a black slab
        // bolted to the edge of the screen in both appearances, so its ink and
        // its readings have to resolve against what they are actually drawn on
        // rather than against the system setting.
        .environment(\.colorScheme, .dark)
    }
}

/// A 46 pt ring with its tag inside and its percentage beneath.
private struct NotchRingView: View {
    let reading: NotchReading
    let color: Color
    let selected: Bool
    let scale: CGFloat

    private var s: CGFloat { scale }

    var body: some View {
        VStack(spacing: NotchMetrics.labelGap(scale: s)) {
            ZStack {
                if selected {
                    Circle().fill(Tokens.notchHaloC)
                }
                Canvas { ctx, size in draw(ctx, size) }
                Text(reading.tag)
                    .font(Typo.mono(9.5 * s, .semibold))
                    .tracking(0.06 * 9.5 * s)
                    .foregroundColor(Tokens.inkC)
            }
            .frame(width: NotchMetrics.haloDiameter(scale: s),
                   height: NotchMetrics.haloDiameter(scale: s))

            Text(Fmt.percent(reading.pct))
                .font(Typo.mono(12 * s, .semibold))
                .foregroundColor(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.accessibilityLabel)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = NotchMetrics.ringRadius(scale: s)
        let w = NotchMetrics.ringStroke(scale: s)
        let circle = Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r,
                                            width: r * 2, height: r * 2))

        ctx.stroke(circle, with: .color(Tokens.notchTrackC),
                   style: StrokeStyle(lineWidth: w, lineCap: .butt))

        guard let pct = reading.pct else {
            // No reading has ever arrived. A dashed ring over the track, never
            // an arc of length zero — an empty ring and an unknown one have to
            // look different or the strip lies by omission.
            ctx.stroke(circle, with: .color(Tokens.dormantC),
                       style: StrokeStyle(lineWidth: w, dash: [3 * s, 5 * s]))
            return
        }
        ctx.stroke(arc(centre: centre, radius: r, fraction: min(1, max(0, pct / 100))),
                   with: .color(color),
                   style: StrokeStyle(lineWidth: w, lineCap: .round))
    }

    /// From 12 o'clock, clockwise, computed pointwise — the construction
    /// `MenubarIcon.arcPath` uses and for its reason
    /// (`MenubarIcon.swift:89-90`).
    private func arc(centre: CGPoint, radius: CGFloat, fraction: Double) -> Path {
        var path = Path()
        let steps = max(2, Int(64 * fraction))
        for i in 0...steps {
            let theta = 2 * Double.pi * fraction * Double(i) / Double(steps)
            let p = CGPoint(x: centre.x + radius * sin(theta),
                            y: centre.y - radius * cos(theta))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}
