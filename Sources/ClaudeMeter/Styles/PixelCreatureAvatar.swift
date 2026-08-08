import SwiftUI

/// 03 · Creature — pixel. 48×48 pt, drawn on a 3 pt grid.
///
/// The grid is the point: state changes read as whole-pixel jumps rather than
/// smooth morphs, which keeps the character legible at 1× and makes it feel
/// like it belongs to the terminal it is watching. Body is brand orange at
/// rest — only escalation re-tints it, so orange means "fine".
///
/// It is the one style that moves in every state rather than only in critical,
/// and nothing in it eases. A `TimelineView` hands each draw the clock,
/// `PixelMotion` quantises that into whole frames, and the canvas paints what
/// it is told — there is no `withAnimation` here and there must not be one,
/// because an interpolated sprite stops looking drawn.
struct PixelCreatureAvatar: View {
    let input: AvatarInput

    // 3 pt units at 1×, so pixels stay whole at 1× and 2×.
    private static let u: CGFloat = 3
    private static let ox: CGFloat = 6
    private static let oy: CGFloat = 9
    /// Features are fixed dark on a coloured body, in both appearances —
    /// flipping them to white in dark mode would erase them on the orange.
    private static let featureInk = Color(nsColor: NSColor(hex: 0x1D1D1F))

    /// A state change is half a second quantised to four frames.
    private static let morphSeconds: Double = 0.5
    /// How far the sunglasses travel to clear the head entirely.
    private static let visorRise: CGFloat = 9

    var body: some View {
        // Sampled at its steps rather than at a frame rate: see
        // `PixelStepSchedule`. `frame(at:)` ignores the clock when motion is
        // off, so what a frozen timeline holds is the rest frame rather than
        // whichever instant the renderer happened to catch.
        TimelineView(schedule) { timeline in
            let f = frame(at: timeline.date.timeIntervalSinceReferenceDate)
            Canvas { ctx, _ in draw(&ctx, f) }.frame(width: 48, height: 48)
        }
        .frame(width: 48, height: 48)
    }

    /// The instants at which this creature, in this state, can change frame.
    ///
    /// A morph runs both states' cycles, because which one is on screen flips
    /// halfway through it.
    private var schedule: PixelStepSchedule {
        guard input.animates else { return PixelStepSchedule(steps: []) }
        // Cycles keyed to a state change count from it; without that history
        // they free-run off the wall clock, which is an origin of zero.
        let cue = input.stateChangedAt ?? 0
        var steps = Self.cycleSteps(input.state, cue: cue)
        guard morphs, let changed = input.stateChangedAt else {
            return PixelStepSchedule(steps: steps)
        }
        let prev = input.previousState ?? input.state
        steps += Self.cycleSteps(prev, cue: cue)
        // The pose morph, and the sunglasses when one end of the change is calm.
        // Both stop mattering the moment they finish, so they expire.
        steps.append(PixelStep(origin: changed, period: 0.125, phase: 0.0625,
                               until: changed + Self.morphSeconds))
        if input.state == .calm {
            steps.append(PixelStep(origin: changed, period: 0.15, phase: 0.075,
                                   until: changed + 0.6))
        }
        return PixelStepSchedule(steps: steps)
    }

    /// When each state's continuous cycles change value. These mirror the
    /// arithmetic in `frame(at:)` exactly — a step function sampled anywhere
    /// other than its own steps either stutters or wastes the wake-up.
    private static func cycleSteps(_ state: MeterState, cue: Double) -> [PixelStep] {
        switch state {
        case .calm:
            return [PixelStep(origin: 0, period: 0.9)]              // idle bob
        case .focused:
            return [PixelStep(origin: 0, period: 0.9),
                    PixelStep(origin: cue, period: 1.7),            // blink shut
                    PixelStep(origin: cue, period: 1.7, phase: 0.14)]  // and open
        case .strained:
            // Five steps down plus the snap back to the top of the fall.
            return [PixelStep(origin: cue, period: 1.1),
                    PixelStep(origin: cue, period: 0.22, phase: 0.11)]
        case .critical:
            return [PixelStep(origin: cue, period: 0.35),           // shake
                    PixelStep(origin: cue, period: 1.1),            // blink shut
                    PixelStep(origin: cue, period: 1.1, phase: 0.16)]
        case .asleep:
            // Breath, plus six steps of drift and the glyphs' return.
            return [PixelStep(origin: cue, period: 1.2),
                    PixelStep(origin: cue, period: 2),
                    PixelStep(origin: cue, period: 2 / 6, phase: 2 / 12)]
        case .stale, .noData, .empty:
            return []
        }
    }

    /// True when there is a pose to morph out of. `empty` is excluded at both
    /// ends: it draws a silhouette rather than a creature, so tweening into or
    /// out of it would interpolate a body that is not on screen.
    private var morphs: Bool {
        guard let prev = input.previousState, input.stateChangedAt != nil,
              prev != input.state else { return false }
        return prev != .empty && input.state != .empty
    }

    // MARK: - Frame

    /// Resolves the clock into one drawable frame. All the timing lives here so
    /// the drawing below is a pure function of a struct.
    private func frame(at now: Double) -> PixelFrame {
        let live = input.animates
        let state = input.state
        let prev = input.previousState ?? state
        let elapsed = max(0, now - (input.stateChangedAt ?? now))

        let p: CGFloat = (live && morphs)
            ? PixelMotion.stepped(CGFloat(elapsed / Self.morphSeconds), 4)
            : 1
        // The reference swaps the marks halfway through the morph and the tint
        // a quarter of the way in, so the colour leads the costume change and
        // neither ever lands on a half-drawn face.
        let marks = p > 0.5 ? state : prev
        var pose = PixelPose.between(.forState(prev), .forState(state), p)

        // Cycles run from the moment the state changed when that is known, so a
        // blink or a falling drop starts at the top of its arc instead of
        // wherever the wall clock happens to be standing. Surfaces with no
        // history — the settings preview, the offscreen renderers — free-run.
        let cue = input.stateChangedAt == nil ? now : elapsed

        var yOff: CGFloat = 0, xOff: CGFloat = 0
        var blink = false, critBlink = false
        var sweat: CGFloat?
        var zRise: CGFloat = 0
        if live {
            switch marks {
            case .calm, .focused:
                yOff = PixelMotion.toggle(now, period: 0.9, amount: 0.4)
            case .critical:
                // A shift, not a hop: the old jump read as pleased with itself,
                // and panic is lateral. Half a unit either side — one unit of
                // travel, as the reference authored it. Trying the spec text's
                // literal ±1 at the default 1.75× read as the window being
                // dragged rather than as a creature trembling, and put the arms
                // on the edge of the plate at the extremes.
                xOff = PixelMotion.toggle(cue, period: 0.35, amount: 1) - 0.5
            case .asleep:
                pose.bh += PixelMotion.toggle(cue, period: 1.2, amount: 0.4)
            default:
                break
            }
            blink = marks == .focused && cue > 0.8
                && cue.truncatingRemainder(dividingBy: 1.7) < 0.14
            critBlink = marks == .critical && cue > 0.6
                && cue.truncatingRemainder(dividingBy: 1.1) < 0.16
            if marks == .strained && cue > 0.3 {
                sweat = PixelMotion.cycle(cue, period: 1.1, steps: 5)
            }
            if marks == .asleep && cue > 0.4 {
                zRise = PixelMotion.cycle(cue, period: 2, steps: 6)
            }
        }

        // Calm is the only state that wears the sunglasses, so putting them on
        // and taking them off is the state change itself rather than a cycle:
        // up over half a second, back down over six tenths.
        var visor: CGFloat = state == .calm ? 0 : -Self.visorRise
        if live && morphs {
            if prev == .calm {
                visor = -Self.visorRise * PixelMotion.stepped(CGFloat(elapsed / 0.5), 4)
            } else if state == .calm {
                visor = -Self.visorRise
                    + Self.visorRise * PixelMotion.stepped(CGFloat(elapsed / 0.6), 4)
            }
        }

        return PixelFrame(pose: pose, marks: marks,
                          fill: Self.bodyFill(p > 0.25 ? state : prev),
                          xOff: xOff, yOff: yOff, blink: blink, critBlink: critBlink,
                          visor: visor, sweat: sweat, zRise: zRise)
    }

    private static func bodyFill(_ state: MeterState) -> Color {
        switch state {
        case .strained: return Tokens.strainedC
        case .critical: return Tokens.criticalC
        case .asleep:   return Tokens.calmC
        case .stale:    return Color(nsColor: NSColor(hex: 0x98989D))
        case .empty:    return .clear
        default:        return Tokens.brandOrangeC
        }
    }

    // MARK: - Drawing

    private func px(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: Self.ox + x * Self.u, y: Self.oy + y * Self.u,
               width: w * Self.u, height: h * Self.u)
    }

    private func draw(_ ctx: inout GraphicsContext, _ f: PixelFrame) {
        // Chrome follows the marks rather than the incoming state, so the ring,
        // the dimming and the badges arrive with the face they belong to.
        let ink = AvatarInk(f.marks, showsBackground: input.showsBackground)
        AvatarChrome.ground(&ctx, rect: CGRect(x: 1.5, y: 1.5, width: 45, height: 45),
                            radius: 14, ink: ink)
        drawCreature(&ctx, f)

        switch f.marks {
        case .asleep:
            drawSleepMarks(&ctx, ink: ink, rise: f.zRise)
        case .stale:
            AvatarChrome.cobweb(&ctx, ink: ink)
            AvatarChrome.clock(&ctx, at: CGPoint(x: 10, y: 10), ink: ink)
        case .noData:
            AvatarChrome.text(&ctx, "?", at: CGPoint(x: 35, y: 12), size: 12,
                              color: ink.inkSoft, weight: .heavy)
        default:
            break
        }
    }

    /// The creature itself, without the ground or the corner marks. Everything
    /// in here rides the frame's offset, which is what makes the bob and the
    /// critical shake move the whole character in one piece.
    private func drawCreature(_ ctx: inout GraphicsContext, _ f: PixelFrame) {
        let ink = Self.featureInk
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                  _ c: Color, opacity: Double = 1) {
            guard w > 0, h > 0 else { return }
            ctx.opacity = opacity
            ctx.fill(Path(px(x + f.xOff, y + f.yOff, w, h)), with: .color(c))
            ctx.opacity = 1
        }

        // Nothing here is alive, so it neither moves nor morphs.
        guard f.marks != .empty else {
            ctx.opacity = 0.8
            ctx.stroke(Path(px(2, -1, 8, 6)), with: .color(Tokens.calmC),
                       style: StrokeStyle(lineWidth: 1.1, dash: [3, 3]))
            ctx.opacity = 1
            return
        }

        let pose = f.pose
        rect(pose.bx, pose.by, pose.bw, pose.bh, f.fill)
        rect(pose.ax1, pose.ay, pose.aw, pose.ah, f.fill)
        rect(pose.ax2, pose.ay, pose.aw, pose.ah, f.fill)
        for leg in pose.legs { rect(leg.x, pose.legY, 1, leg.h, f.fill) }

        switch f.marks {
        case .asleep:
            rect(3.5, 7.4, 1.4, 0.45, ink)
            rect(7, 7.4, 1.4, 0.45, ink)

        case .critical:
            if f.critBlink {
                rect(3.4, 0.8, 2, 0.4, ink)
                rect(6.6, 0.8, 2, 0.4, ink)
            } else {
                rect(3.4, 0, 2, 2, .white)
                rect(6.6, 0, 2, 2, .white)
                rect(4, 0.5, 0.9, 0.9, ink)
                rect(7.2, 0.5, 0.9, 0.9, ink)
            }

        case .stale:
            // Hollow eyes: the lights are on but nothing is reporting.
            for x in [pose.eyeX1, pose.eyeX2] {
                ctx.stroke(Path(px(x + f.xOff, pose.eyeY + f.yOff, pose.eyeW, pose.eyeW)),
                           with: .color(ink), lineWidth: 1)
            }

        default:
            // Calm's eyes only matter once the visor starts to lift. Painting
            // them under a lens that covers them exactly leaves an antialiased
            // seam along the lens edge and nothing else.
            if f.marks == .calm && f.visor == 0 { break }
            // A blink collapses the eye about its own centre rather than
            // dropping its lid, which on a 1.3 u square is the difference
            // between a blink and a squint.
            let dx: CGFloat = f.marks == .noData ? -0.5 : 0
            let h = f.blink ? 0.25 : pose.eyeW
            let y = pose.eyeY + (pose.eyeW - h) / 2
            rect(pose.eyeX1 + dx, y, pose.eyeW, h, ink)
            rect(pose.eyeX2 + dx, y, pose.eyeW, h, ink)
        }

        if f.marks == .strained {
            rect(2.9, 2.1, 1.7, 0.5, ink)   // brows
            rect(7.4, 2.1, 1.7, 0.5, ink)
            rect(11.3, -0.5, 1, 1, Tokens.calmC)
            rect(11.7, 0.9, 0.7, 0.7, Tokens.calmC)
        }

        // The falling drop exists only while the creature is animating. Parked
        // at the top of its fall it would read as a third sweat pixel, and the
        // two the anatomy specifies are what the still frame is meant to show.
        if let s = f.sweat {
            rect(10.2, 1.8 + s * 3.8, 0.9, 0.9, Tokens.calmC,
                 opacity: Double(1 - s * 0.5))
        }

        // Drawn over the eyes, which is why the eyes are drawn at all in calm:
        // sliding the visor up has to reveal something.
        if f.visor > -8.5 {
            let d = f.visor
            rect(3.5, 0.3 + d, 2.3, 1.5, ink)
            rect(6.3, 0.3 + d, 2.3, 1.5, ink)
            rect(5.8, 0.5 + d, 0.5, 0.5, ink)   // bridge
            rect(2.7, 0.4 + d, 0.8, 0.45, ink)  // temples
            rect(8.6, 0.4 + d, 0.8, 0.45, ink)
        }

        // Mini creatures for the extra sessions, each tinted by its own
        // reading, so a hot session cannot hide behind a calm leader.
        if input.isMany && !f.marks.isException {
            drawCompanions(&ctx, ink: ink)
        }
    }

    /// The sleep glyphs drift up and fade over their cycle. At rest they sit
    /// exactly where `AvatarChrome.zzz` puts them, so the frozen frame is the
    /// one this style has always drawn.
    private func drawSleepMarks(_ ctx: inout GraphicsContext, ink: AvatarInk, rise: CGFloat) {
        let travel = rise * 6
        let fade = { (a: CGFloat) in Double(min(max(a, 0), 1)) }
        AvatarChrome.text(&ctx, "z", at: CGPoint(x: 35, y: 22 - travel), size: 9,
                          color: ink.inkSoft.opacity(fade(1 - rise)), weight: .bold)
        AvatarChrome.text(&ctx, "z", at: CGPoint(x: 39.5, y: 15.5 - travel), size: 6.5,
                          color: ink.inkSoft.opacity(fade(1 - rise * 1.4)), weight: .bold)
    }

    private func drawCompanions(_ ctx: inout GraphicsContext, ink: Color) {
        let t = SettingsStore.shared.thresholds
        let others = input.sessions.compactMap { $0 }.sorted(by: >).dropFirst().prefix(2)
        let slots: [(CGFloat, CGFloat, CGFloat)] = [(9.6, 7, 3), (10.8, 3, 2.4)]
        for (i, pct) in others.enumerated() where i < slots.count {
            let (x, y, w) = slots[i]
            let c = t.state(for: pct).color
            ctx.fill(Path(px(x, y, w, w * 0.75)), with: .color(c))
            ctx.fill(Path(px(x + w * 0.2, y + w * 0.2, 0.9, 0.9)), with: .color(ink))
        }
    }
}

// MARK: - Motion

/// The three primitives the animated reference is built from, and the only ones
/// this style is allowed. Anything that cannot be written as one of them is an
/// easing curve in disguise, and an eased sprite stops reading as pixel art.
private enum PixelMotion {

    /// Quantises a 0…1 ramp into `steps` discrete frames.
    static func stepped(_ p: CGFloat, _ steps: CGFloat) -> CGFloat {
        (min(max(p, 0), 1) * steps).rounded() / steps
    }

    /// A two-frame toggle: at rest for one period, displaced for the next.
    static func toggle(_ t: Double, period: Double, amount: CGFloat) -> CGFloat {
        Int(floor(max(0, t) / period)) % 2 == 0 ? 0 : amount
    }

    /// A stepped ramp that restarts every `period`.
    static func cycle(_ t: Double, period: Double, steps: CGFloat) -> CGFloat {
        stepped(CGFloat(max(0, t).truncatingRemainder(dividingBy: period) / period), steps)
    }
}

/// One repeating instant: `origin + phase + k · period`, until it expires.
private struct PixelStep {
    var origin: Double
    var period: Double
    /// Where in the period the value actually changes. A stepped ramp rounds,
    /// so it turns over half a step in, not on the boundary.
    var phase: Double = 0
    /// The instant past which this cycle stops firing — a morph is over.
    var until: Double = .infinity

    /// The first change strictly after `t`, nudged a hair past the boundary so
    /// that a frame computed at that instant lands on the new step rather than
    /// on the wrong side of a rounding error.
    func next(after t: Double) -> Double? {
        let base = origin + phase
        var v = base + (floor((t - base) / period) + 1) * period
        while v <= t { v += period }
        return v <= until ? v + Self.nudge : nil
    }

    /// The most recent change at or before `t` — the instant the frame on
    /// screen right now belongs to.
    func latest(atOrBefore t: Double) -> Double {
        let cap = min(t, until)
        let base = origin + phase
        var v = base + floor((cap - base) / period) * period
        while v > cap { v -= period }
        return v + Self.nudge
    }

    private static let nudge = 0.001
}

/// Wakes the sprite only when it can actually change.
///
/// Every cycle in this style is a step function held for at least an eighth of
/// a second, so a fixed frame rate spends almost every wake-up redrawing a
/// frame identical to the last. At 30 Hz that measured six times the app's idle
/// CPU, which for something launched at login and kept alive all day is the
/// difference between unnoticed and uninstalled. Sampling the steps themselves
/// costs about one redraw a second when calm and under five in the busiest
/// state, and — because the sprite only has those frames — looks the same.
private struct PixelStepSchedule: TimelineSchedule {
    var steps: [PixelStep]

    /// How long to wait when nothing is moving. Not forever, because the
    /// schedule is only re-read when the view updates, and a parked one must
    /// never be able to hold the sprite on a stale frame indefinitely.
    private static let parked: Double = 5

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        // Off-screen or in low power, the schedule is a promise to redraw that
        // nobody is looking at.
        let steps = mode == .lowFrequency ? [] : self.steps
        let now = startDate.timeIntervalSinceReferenceDate
        // The sequence opens on the step the current frame belongs to, not on
        // "now". The panel rebuilds this schedule once a second when the store
        // ticks, and an entry dated now reads as one that is due now — which
        // cost a whole extra redraw per second for a frame that had not
        // changed. The last boundary is the same date every time until the
        // sprite actually moves.
        var t = steps.map { $0.latest(atOrBefore: now) }.max()
            ?? (now / Self.parked).rounded(.down) * Self.parked
        var first = true
        return AnySequence {
            AnyIterator {
                if first {
                    first = false
                    return Date(timeIntervalSinceReferenceDate: t)
                }
                let next = steps.compactMap { $0.next(after: max(t, now)) }.min()
                    ?? (max(t, now) + Self.parked)
                t = next
                return Date(timeIntervalSinceReferenceDate: next)
            }
        }
    }
}

/// Everything one frame needs, resolved from the clock before the canvas opens.
private struct PixelFrame {
    var pose: PixelPose
    /// The state whose marks, ground and badges this frame wears. It only
    /// becomes the incoming state once the morph is more than half done.
    var marks: MeterState
    var fill: Color
    /// Whole-frame displacement of the entire creature, in grid units.
    var xOff: CGFloat
    var yOff: CGFloat
    var blink: Bool
    var critBlink: Bool
    /// Sunglasses offset: 0 worn, −9 once clear of the head.
    var visor: CGFloat
    /// How far the sweat drop has fallen, 0…1, or nil when it is not drawn.
    var sweat: CGFloat?
    /// How far the sleep glyphs have drifted, 0…1 of their travel.
    var zRise: CGFloat
}

/// A silhouette, as numbers. Every field is a grid coordinate so two states can
/// be blended by walking them — which is the whole pose morph, and the reason
/// the poses are a table rather than a switch full of literals.
private struct PixelPose {
    var bx, by, bw, bh: CGFloat
    var ax1, ax2, ay, aw, ah: CGFloat
    var legY: CGFloat
    /// Always four, so two poses can be zipped leg for leg.
    var legs: [Leg]
    var eyeX1, eyeX2, eyeY, eyeW: CGFloat

    struct Leg { var x: CGFloat; var h: CGFloat }

    static let idle = PixelPose(
        bx: 2, by: -1, bw: 8, bh: 6,
        ax1: 0, ax2: 10, ay: 1.5, aw: 2, ah: 2,
        legY: 5, legs: [Leg(x: 2, h: 2.5), Leg(x: 4, h: 2.5),
                        Leg(x: 7, h: 2.5), Leg(x: 9, h: 2.5)],
        eyeX1: 4, eyeX2: 6.7, eyeY: 0.3, eyeW: 1.3)

    /// Squashed, braced, eyes low under the brows.
    static let strained = PixelPose(
        bx: 1, by: 1.5, bw: 10, bh: 4.5,
        ax1: -0.5, ax2: 10.5, ay: 3, aw: 2, ah: 2,
        legY: 6, legs: [Leg(x: 1, h: 2), Leg(x: 3, h: 1.6),
                        Leg(x: 7, h: 2), Leg(x: 10, h: 1.6)],
        eyeX1: 3.4, eyeX2: 7.3, eyeY: 2.9, eyeW: 1.3)

    /// Flat on the ground. The limbs are kept at zero height rather than
    /// dropped, so a creature lying down is the same four legs folded away.
    static let asleep = PixelPose(
        bx: 1, by: 6.5, bw: 10, bh: 3,
        ax1: 1, ax2: 10, ay: 7, aw: 2, ah: 0,
        legY: 9, legs: [Leg(x: 2, h: 0), Leg(x: 4, h: 0),
                        Leg(x: 7, h: 0), Leg(x: 9, h: 0)],
        eyeX1: 4, eyeX2: 6.7, eyeY: 7.4, eyeW: 1.3)

    /// The idle stance with the eyes wide open — the panic is in the eyes, not
    /// the stance, so a morph into critical only has to grow them.
    static var critical: PixelPose {
        var p = idle
        p.eyeY = 0
        p.eyeW = 2
        return p
    }

    static func forState(_ s: MeterState) -> PixelPose {
        switch s {
        case .strained: return .strained
        case .critical: return .critical
        case .asleep:   return .asleep
        default:        return .idle
        }
    }

    static func between(_ a: PixelPose, _ b: PixelPose, _ p: CGFloat) -> PixelPose {
        guard p < 1 else { return b }
        func m(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * p }
        return PixelPose(
            bx: m(a.bx, b.bx), by: m(a.by, b.by), bw: m(a.bw, b.bw), bh: m(a.bh, b.bh),
            ax1: m(a.ax1, b.ax1), ax2: m(a.ax2, b.ax2), ay: m(a.ay, b.ay),
            aw: m(a.aw, b.aw), ah: m(a.ah, b.ah),
            legY: m(a.legY, b.legY),
            legs: zip(a.legs, b.legs).map { Leg(x: m($0.x, $1.x), h: m($0.h, $1.h)) },
            eyeX1: m(a.eyeX1, b.eyeX1), eyeX2: m(a.eyeX2, b.eyeX2),
            eyeY: m(a.eyeY, b.eyeY), eyeW: m(a.eyeW, b.eyeW))
    }
}
