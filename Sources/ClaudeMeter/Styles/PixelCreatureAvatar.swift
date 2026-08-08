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

    /// The laptop is its own object rather than part of the creature, so it
    /// keeps its own colours in both appearances — a machine that changed
    /// colour with the system theme would read as part of the character.
    private static let laptopBase = Color(nsColor: NSColor(hex: 0x6E7076))
    private static let laptopLid = Color(nsColor: NSColor(hex: 0x3A3C42))
    private static let laptopScreen = Color(nsColor: NSColor(hex: 0x10131A))
    private static let codeInk = [0x7FA8E8, 0x8BC48A, 0xC9A15E]
        .map { Color(nsColor: NSColor(hex: $0)) }
    private static let cursorInk = Color(nsColor: NSColor(hex: 0xF5F5F7))

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
        // A run only ever plays over calm or focused, so only those two carry
        // its wake-ups. The list covers the run playing now and the next one,
        // and is empty in between — the schedule that idles is the same one it
        // was before any of this existed.
        let instants = (input.state == .calm || input.state == .focused)
            ? PixelCoding.instants(around: Date().timeIntervalSinceReferenceDate)
            : []
        guard morphs, let changed = input.stateChangedAt else {
            return PixelStepSchedule(steps: steps, instants: instants)
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
        return PixelStepSchedule(steps: steps, instants: instants)
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
        case .critical:
            return [PixelStep(origin: cue, period: 0.35),           // shake
                    PixelStep(origin: cue, period: 1.1),            // blink shut
                    PixelStep(origin: cue, period: 1.1, phase: 0.16)]
        case .asleep:
            // Breath, plus six steps of drift and the glyphs' return.
            return [PixelStep(origin: cue, period: 1.2),
                    PixelStep(origin: cue, period: 2),
                    PixelStep(origin: cue, period: 2 / 6, phase: 2 / 12)]
        // Strained lost its sweat pixels and with them its only cycle: the
        // squashed pose, the brows and the tint carry it now, and all four of
        // these are still pictures.
        case .strained, .stale, .noData, .empty:
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
        // blink or a breath starts at the top of its arc instead of wherever
        // the wall clock happens to be standing. Surfaces with no history — the
        // settings preview, the offscreen renderers — free-run instead.
        let cue = input.stateChangedAt == nil ? now : elapsed

        // The coding flourish rides on top of calm and focused rather than
        // being a state of its own, so nothing upstream knows about it. It
        // never starts mid-morph — a creature changing colour while hauling a
        // laptop about reads as two animations fighting.
        var coding: CodingFrame?
        if live, p >= 1, state == .calm || state == .focused,
           let e = PixelCoding.elapsed(at: now) {
            coding = PixelCoding.frame(at: e)
        }

        var yOff: CGFloat = 0, xOff: CGFloat = 0
        var blink = false, critBlink = false
        var zRise: CGFloat = 0
        if live {
            switch marks {
            case .calm, .focused:
                // A run holds the creature still for the middle of itself; the
                // bob survives at both ends.
                if coding?.bobs ?? true {
                    yOff = PixelMotion.toggle(now, period: 0.9, amount: 0.4)
                }
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
            // Squinting at a screen outranks blinking at nothing.
            blink = marks == .focused && !(coding?.typing ?? false) && cue > 0.8
                && cue.truncatingRemainder(dividingBy: 1.7) < 0.14
            critBlink = marks == .critical && cue > 0.6
                && cue.truncatingRemainder(dividingBy: 1.1) < 0.16
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
                          visor: visor, zRise: zRise, coding: coding)
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
        // While a laptop is out, the arms are placed by the flourish instead of
        // by the pose: they reach down for it, rise with the lid, then hammer
        // at different heights, which one shared `ay` cannot say.
        if let c = f.coding {
            rect(c.armX1, c.armY1, pose.aw, pose.ah, f.fill)
            rect(c.armX2, c.armY2, pose.aw, pose.ah, f.fill)
        } else {
            rect(pose.ax1, pose.ay, pose.aw, pose.ah, f.fill)
            rect(pose.ax2, pose.ay, pose.aw, pose.ah, f.fill)
        }
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
            // Squinting at the screen: shorter eyes, dropped rather than
            // centred, which is what reads as concentration instead of a blink.
            if f.coding?.typing == true {
                rect(pose.eyeX1, pose.eyeY + 0.3, pose.eyeW, 0.8, ink)
                rect(pose.eyeX2, pose.eyeY + 0.3, pose.eyeW, 0.8, ink)
                break
            }
            // A blink collapses the eye about its own centre rather than
            // dropping its lid, which on a 1.3 u square is the difference
            // between a blink and a squint.
            let dx: CGFloat = f.marks == .noData ? -0.5 : 0
            let h = f.blink ? 0.25 : pose.eyeW
            let y = pose.eyeY + (pose.eyeW - h) / 2
            rect(pose.eyeX1 + dx, y, pose.eyeW, h, ink)
            rect(pose.eyeX2 + dx, y, pose.eyeW, h, ink)
        }

        // Brows, and no sweat. The design brief puts two grey pixels off the
        // upper-right shoulder and a third falling past them, but detached from
        // the silhouette on a dark desktop they read as stuck pixels rather
        // than as sweat. Strained still has three cues without them — the
        // squashed pose, the brows, and the orange tint.
        if f.marks == .strained {
            rect(2.9, 2.1, 1.7, 0.5, ink)
            rect(7.4, 2.1, 1.7, 0.5, ink)
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

        // Last, and deliberately not offset by the bob: the laptop is a
        // separate object, and on the way out it passes across the body, which
        // is what sells it being pulled from behind.
        if let c = f.coding { drawLaptop(&ctx, c) }
    }

    /// The laptop, from the moment it clears the creature to the moment it goes
    /// back behind it. Every coordinate is the reference composition's.
    private func drawLaptop(_ ctx: inout GraphicsContext, _ c: CodingFrame) {
        guard c.pullOut > 0 else { return }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ col: Color) {
            guard w > 0, h > 0 else { return }
            ctx.fill(Path(px(x, y, w, h)), with: .color(col))
        }
        // It rises into place from three and a half units higher up, behind
        // the body, and lands in front of the feet.
        let baseY = 8.2 - 3.5 * (1 - c.pullOut)
        rect(2.5, baseY, 7, 0.9, Self.laptopBase)

        guard c.lidUp > 0 else {
            rect(2.7, baseY - 0.5, 6.6, 0.5, Self.laptopLid)   // still shut
            return
        }
        let lidH = 4.6 * c.lidUp
        rect(2.7, baseY - lidH, 6.6, lidH, Self.laptopLid)
        // The screen only exists once there is a lid to put it in.
        guard c.lidUp > 0.6 else { return }
        rect(3.2, baseY - lidH + 0.5, 5.6, lidH - 1, Self.laptopScreen)

        // Code fills the screen a line at a time. `bars` is zero the instant
        // typing stops, which is the whole point: bars that outlive the typing
        // spill out of the shrinking lid.
        for i in 0..<c.bars {
            rect(3.6, baseY - lidH + 0.9 + CGFloat(i) * 0.62,
                 1.8 + CGFloat((i * 37) % 3), 0.32, Self.codeInk[i % 3])
        }
        if c.cursor {
            rect(5.8, baseY - lidH + 0.9 + CGFloat(c.cursorLine) * 0.62,
                 0.3, 0.32, Self.cursorInk)
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

/// Boundaries are handed to the schedule a hair late, so that a frame computed
/// at one lands on the new step rather than on the wrong side of a rounding
/// error and holds the old one until the next wake-up.
private let pixelNudge = 0.001

// MARK: - Coding flourish

/// The "coding on a laptop" run: when one happens, and what it looks like at a
/// given moment inside one.
///
/// It has to be occasional and it has to be a pure function of the clock. The
/// view is a struct rebuilt on every frame and `@State` does not compile in
/// this project, so there is nowhere to keep a die roll. Time is cut into fixed
/// windows instead and the start offset inside each window is hashed from the
/// window's index: any two draws at the same instant agree, the sequence
/// survives every re-render, and it still looks unplanned.
private enum PixelCoding {

    /// One possible run per window, with a third of windows staying quiet.
    /// That is a run roughly every two minutes, with real gaps running from a
    /// few seconds to about four — often enough to be caught, seldom enough to
    /// stay a surprise rather than a metronome.
    static let window: Double = 75
    static let duration: Double = 6.3

    // The run's shape, all of it from the reference composition.
    private static let pullSpan = 0.7
    private static let lidDelay = 0.8, lidSpan = 0.8
    private static let typeStart = 2.0, typeSpan = 3.0
    private static let closeStart = 5.0, closeSpan = 0.6
    private static let awayStart = 5.7, awaySpan = 0.6
    /// Each arm toggles on this period; they are half a beat out of phase.
    private static let hammer = 0.14
    private static let cursorBlink = 0.4

    /// splitmix64's finaliser. Cheap, and mixed well enough that consecutive
    /// windows do not produce neighbouring offsets — which is what would make
    /// the runs feel evenly spaced.
    private static func hash(_ k: Int) -> UInt64 {
        var x = UInt64(bitPattern: Int64(k)) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        return x ^ (x >> 31)
    }

    /// When this window's run begins, or nil for a quiet one. Offsets are
    /// clamped so a run can never straddle two windows, which keeps "is one
    /// playing?" a single lookup.
    static func start(ofWindow k: Int) -> Double? {
        let h = hash(k)
        guard h % 3 != 0 else { return nil }
        let offset = Double((h >> 8) % 100_000) / 100_000 * (window - duration)
        return Double(k) * window + offset
    }

    /// Seconds into a run, or nil when none is playing.
    static func elapsed(at t: Double) -> Double? {
        guard let s = start(ofWindow: Int(floor(t / window))) else { return nil }
        let e = t - s
        return (e >= 0 && e < duration) ? e : nil
    }

    /// Every instant a run changes frame: the one just finished, the one
    /// playing, and the next.
    ///
    /// The next one is included because the schedule is only rebuilt when the
    /// view updates; without it a run would be discovered up to a second late
    /// and start halfway through its own slide.
    ///
    /// The one just finished is included for a subtler reason. The schedule
    /// names the current frame by the newest boundary at or before now, which
    /// is only correct while every cycle that could have moved since is on the
    /// list. Drop a finished run too early and the newest boundary left is the
    /// bob's, up to 0.9 s old — and the sprite redraws a frame from the middle
    /// of a run it has already finished, laptop and all. Measured, not
    /// theorised: it put the laptop back on screen for half a second.
    static func instants(around t: Double) -> [Double] {
        var out: [Double] = []
        var found = 0
        let k = Int(floor(t / window))
        for i in 0...12 where found < 2 {
            guard let s = start(ofWindow: k + i), s + duration >= t - lookback else { continue }
            out += steps(from: s)
            found += 1
        }
        return out.filter { $0 >= t - lookback }
    }

    /// How far back a boundary stays useful for naming the current frame. Has
    /// to outlast the slowest cycle the sprite runs between runs.
    private static let lookback = 2.0

    /// One frame of a run.
    static func frame(at e: Double) -> CodingFrame {
        let out = PixelMotion.stepped(CGFloat(e / pullSpan), 5)
        let away = e < awayStart ? 0
            : PixelMotion.stepped(CGFloat((e - awayStart) / awaySpan), 4)
        let open = e < lidDelay ? 0
            : PixelMotion.stepped(CGFloat((e - lidDelay) / lidSpan), 5)
        let close = e < closeStart ? 0
            : PixelMotion.stepped(CGFloat((e - closeStart) / closeSpan), 4)
        let typing = e >= typeStart && e < typeStart + typeSpan

        // Arms: down to drag the laptop out, rising as the lid does, then
        // hammering alternately once there is something to type on.
        var x1: CGFloat = 0, x2: CGFloat = 10, y1: CGFloat = 1.5, y2: CGFloat = 1.5
        let pullOut = max(0, out - away)
        let lidUp = max(0, open - close)
        if typing {
            let t = e - typeStart
            x1 = 0.8; x2 = 9.2
            y1 = 2.6 + PixelMotion.toggle(t, period: hammer, amount: 1.2)
            y2 = 2.6 + PixelMotion.toggle(t + hammer / 2, period: hammer, amount: 1.2)
        } else if pullOut > 0 && pullOut < 1 {
            x1 = 0.5; x2 = 9.5; y1 = 3.5; y2 = 3.5
        } else if lidUp > 0 {
            x1 = 0.5; x2 = 9.5; y1 = 1.5 + 2 * lidUp; y2 = y1
        }

        // Lines appear one at a time, and are gone the instant typing stops —
        // the lid does not start shrinking for another 75 ms, which is the
        // margin that keeps code from spilling out of it.
        var bars = 0, line = 0, cursor = false
        if typing {
            let t = e - typeStart
            let filled = PixelMotion.cycle(t, period: typeSpan, steps: 6) * 5
            bars = min(5, 1 + Int(filled))
            line = min(4, Int(filled))
            cursor = Int(floor(t / cursorBlink)) % 2 == 1
        }

        // The idle bob survives only at the two ends of a run: before the lid
        // has moved at all, and once it has folded flat again.
        return CodingFrame(pullOut: pullOut, lidUp: lidUp, typing: typing,
                           bars: bars, cursorLine: line, cursor: cursor,
                           armX1: x1, armX2: x2, armY1: y1, armY2: y2,
                           bobs: (!typing && open == 0) || close >= 1)
    }

    /// The instants one run turns over on. Dense in the middle — the hands are
    /// the fastest thing in this style — and nothing at all outside a run.
    private static func steps(from s: Double) -> [Double] {
        var out: [Double] = []
        // A stepped ramp turns over half a step in, hence the +0.5 on each.
        for k in 0..<5 { out.append(s + (Double(k) + 0.5) / 5 * pullSpan) }
        for k in 0..<5 { out.append(s + lidDelay + (Double(k) + 0.5) / 5 * lidSpan) }
        for k in 0..<4 { out.append(s + closeStart + (Double(k) + 0.5) / 4 * closeSpan) }
        for k in 0..<4 { out.append(s + awayStart + (Double(k) + 0.5) / 4 * awaySpan) }
        // Typing starting, and — the one that matters — stopping.
        out.append(s + typeStart)
        out.append(s + typeStart + typeSpan)
        // Hands on every half beat, because the two arms alternate.
        for k in stride(from: 0.0, to: typeSpan, by: hammer / 2) {
            out.append(s + typeStart + k)
        }
        for k in 0..<6 { out.append(s + typeStart + (Double(k) + 0.5) / 6 * typeSpan) }
        for k in stride(from: cursorBlink, to: typeSpan, by: cursorBlink) {
            out.append(s + typeStart + k)
        }
        // And the moment the whole thing is over, so the last frame drawn is
        // the creature standing there with nothing in its hands.
        out.append(s + duration)
        return out.map { $0 + pixelNudge }
    }
}

/// One frame of the coding flourish: where the laptop is, what is on its
/// screen, and where the arms have gone to reach it.
private struct CodingFrame {
    /// 0 hidden behind the creature, 1 fully in front of its feet.
    var pullOut: CGFloat
    /// 0 shut, 1 open to its full 4.6 u.
    var lidUp: CGFloat
    var typing: Bool
    /// How many code lines are on screen, 0…5. Zero unless typing.
    var bars: Int
    var cursorLine: Int
    var cursor: Bool
    var armX1: CGFloat, armX2: CGFloat, armY1: CGFloat, armY2: CGFloat
    /// Whether the idle bob still applies this frame.
    var bobs: Bool
}

// MARK: - Scheduling

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
        return v <= until ? v + pixelNudge : nil
    }

    /// The most recent change at or before `t` — the instant the frame on
    /// screen right now belongs to.
    func latest(atOrBefore t: Double) -> Double {
        let cap = min(t, until)
        let base = origin + phase
        var v = base + floor((cap - base) / period) * period
        while v > cap { v -= period }
        return v + pixelNudge
    }
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
    /// One-off boundaries, for motion that is a sequence rather than a cycle —
    /// the coding flourish. Empty between runs, so idling costs what it always
    /// did however dense a run gets.
    var instants: [Double] = []

    /// How long to wait when nothing is moving. Not forever, because the
    /// schedule is only re-read when the view updates, and a parked one must
    /// never be able to hold the sprite on a stale frame indefinitely.
    private static let parked: Double = 5

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        // Off-screen or in low power, the schedule is a promise to redraw that
        // nobody is looking at.
        let steps = mode == .lowFrequency ? [] : self.steps
        let instants = mode == .lowFrequency ? [] : self.instants
        let now = startDate.timeIntervalSinceReferenceDate
        // The sequence opens on the step the current frame belongs to, not on
        // "now". The panel rebuilds this schedule once a second when the store
        // ticks, and an entry dated now reads as one that is due now — which
        // cost a whole extra redraw per second for a frame that had not
        // changed. The last boundary is the same date every time until the
        // sprite actually moves.
        let settled = steps.map { $0.latest(atOrBefore: now) } + instants.filter { $0 <= now }
        var t = settled.max() ?? (now / Self.parked).rounded(.down) * Self.parked
        var first = true
        return AnySequence {
            AnyIterator {
                if first {
                    first = false
                    return Date(timeIntervalSinceReferenceDate: t)
                }
                let after = max(t, now)
                let next = (steps.compactMap { $0.next(after: after) }
                            + instants.filter { $0 > after }).min()
                    ?? (after + Self.parked)
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
    /// How far the sleep glyphs have drifted, 0…1 of their travel.
    var zRise: CGFloat
    /// The coding flourish, when one is playing.
    var coding: CodingFrame?
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
