import SwiftUI

/// 04 · Creature — blob. 48×48 pt.
///
/// The soft-bodied original, sharing the pixel creature's pose grammar so
/// switching styles never means relearning the language. A creature implies
/// liveness, which makes staleness the dangerous state to fake — so a stale
/// blob visibly stops being alive (grey, dead-eyed, cobwebbed) rather than
/// holding its last pose.
struct BlobCreatureAvatar: View {
    let input: AvatarInput

    private static let featureInk = Color(nsColor: NSColor(hex: 0x1D1D1F))

    var body: some View {
        ZStack {
            Canvas { ctx, _ in draw(&ctx) }.frame(width: 48, height: 48)
            if input.state == .critical {
                BouncingLayer(animates: input.animates) {
                    Canvas { ctx, _ in drawPose(&ctx) }.frame(width: 48, height: 48)
                }
            }
        }
        .frame(width: 48, height: 48)
    }

    private var bodyFill: Color {
        switch input.state {
        case .focused:  return Tokens.focusedC
        case .strained: return Tokens.strainedC
        case .critical: return Tokens.criticalC
        case .asleep:   return Tokens.calmC
        case .stale:    return Color(nsColor: NSColor(hex: 0x98989D))
        case .empty:    return .clear
        default:        return Tokens.dormantC   // calm, no-data
        }
    }

    private func draw(_ ctx: inout GraphicsContext) {
        let ink = AvatarInk(input.state, showsBackground: input.showsBackground)
        AvatarChrome.ground(&ctx, rect: CGRect(x: 1.5, y: 1.5, width: 45, height: 45),
                            radius: 14, ink: ink)
        if input.state != .critical { drawPose(&ctx) }

        switch input.state {
        case .asleep:
            AvatarChrome.zzz(&ctx, big: CGPoint(x: 34, y: 26),
                             small: CGPoint(x: 38.5, y: 19.5), ink: ink)
        case .stale:
            AvatarChrome.cobweb(&ctx, ink: ink)
            AvatarChrome.clock(&ctx, at: CGPoint(x: 10, y: 10), ink: ink)
        case .noData:
            AvatarChrome.text(&ctx, "?", at: CGPoint(x: 33, y: 15), size: 12,
                              color: ink.inkSoft, weight: .heavy)
        default:
            break
        }
    }

    private func drawPose(_ ctx: inout GraphicsContext) {
        let fill = bodyFill
        let ink = Self.featureInk

        func stroke(_ p: Path, _ w: CGFloat) {
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: w, lineCap: .round))
        }
        func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: Color) {
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(c))
        }
        func seg(_ a: CGPoint, _ b: CGPoint, _ w: CGFloat) {
            var p = Path(); p.move(to: a); p.addLine(to: b); stroke(p, w)
        }

        /// Upright resting silhouette.
        func idleBody(_ opacity: Double = 1) {
            var p = Path()
            p.move(to: CGPoint(x: 14, y: 39))
            p.addQuadCurve(to: CGPoint(x: 24, y: 22), control: CGPoint(x: 13, y: 22))
            p.addQuadCurve(to: CGPoint(x: 34, y: 39), control: CGPoint(x: 35, y: 22))
            p.addQuadCurve(to: CGPoint(x: 31, y: 41), control: CGPoint(x: 34, y: 41))
            p.addLine(to: CGPoint(x: 17, y: 41))
            p.addQuadCurve(to: CGPoint(x: 14, y: 39), control: CGPoint(x: 14, y: 41))
            p.closeSubpath()
            ctx.opacity = opacity
            ctx.fill(p, with: .color(fill))
            ctx.opacity = 1
        }

        switch input.state {
        case .calm:
            idleBody()
            dot(20, 30, 1.7, ink); dot(28, 30, 1.7, ink)
            var m = Path()
            m.move(to: CGPoint(x: 21, y: 35))
            m.addQuadCurve(to: CGPoint(x: 27, y: 35), control: CGPoint(x: 24, y: 37))
            stroke(m, 1.6)

        case .noData:
            idleBody()
            dot(20, 30, 1.7, ink); dot(28, 30, 1.7, ink)
            seg(CGPoint(x: 22, y: 35.5), CGPoint(x: 26, y: 35.5), 1.6)

        case .focused:
            // 7° forward lean: working.
            ctx.translateBy(x: 24, y: 41)
            ctx.rotate(by: .degrees(7))
            ctx.translateBy(x: -24, y: -41)
            idleBody()
            dot(22, 30, 1.7, ink); dot(30, 30, 1.7, ink)
            seg(CGPoint(x: 24, y: 35), CGPoint(x: 29, y: 35), 1.6)

        case .strained:
            var b = Path()
            b.move(to: CGPoint(x: 10, y: 40))
            b.addQuadCurve(to: CGPoint(x: 24, y: 27), control: CGPoint(x: 10, y: 27))
            b.addQuadCurve(to: CGPoint(x: 38, y: 40), control: CGPoint(x: 38, y: 27))
            b.addQuadCurve(to: CGPoint(x: 34, y: 42), control: CGPoint(x: 38, y: 42))
            b.addLine(to: CGPoint(x: 14, y: 42))
            b.addQuadCurve(to: CGPoint(x: 10, y: 40), control: CGPoint(x: 10, y: 42))
            b.closeSubpath()
            ctx.fill(b, with: .color(fill))
            seg(CGPoint(x: 16, y: 31), CGPoint(x: 21, y: 33), 1.6)
            seg(CGPoint(x: 32, y: 31), CGPoint(x: 27, y: 33), 1.6)
            dot(19, 35.5, 1.5, ink); dot(29, 35.5, 1.5, ink)
            // Gritted teeth.
            seg(CGPoint(x: 21, y: 39), CGPoint(x: 27, y: 39), 1.2)
            seg(CGPoint(x: 22.5, y: 37.5), CGPoint(x: 22.5, y: 40.5), 1.2)
            seg(CGPoint(x: 25.5, y: 37.5), CGPoint(x: 25.5, y: 40.5), 1.2)
            var sw = Path()
            sw.move(to: CGPoint(x: 38, y: 20))
            sw.addQuadCurve(to: CGPoint(x: 38, y: 27), control: CGPoint(x: 41, y: 25))
            sw.addQuadCurve(to: CGPoint(x: 38, y: 20), control: CGPoint(x: 35, y: 25))
            ctx.fill(sw, with: .color(Tokens.calmC))

        case .critical:
            ctx.translateBy(x: 0, y: -4)
            var b = Path()
            b.move(to: CGPoint(x: 15, y: 40))
            b.addQuadCurve(to: CGPoint(x: 24, y: 24), control: CGPoint(x: 14, y: 24))
            b.addQuadCurve(to: CGPoint(x: 33, y: 40), control: CGPoint(x: 34, y: 24))
            b.addQuadCurve(to: CGPoint(x: 30, y: 42), control: CGPoint(x: 33, y: 42))
            b.addLine(to: CGPoint(x: 18, y: 42))
            b.addQuadCurve(to: CGPoint(x: 15, y: 40), control: CGPoint(x: 15, y: 42))
            b.closeSubpath()
            ctx.fill(b, with: .color(fill))
            dot(20, 31, 2.6, .white); dot(28, 31, 2.6, .white)
            dot(20, 31, 1.2, ink); dot(28, 31, 1.2, ink)
            ctx.translateBy(x: 0, y: 4)
            // Motion lines carry the jump when it cannot animate.
            var ml = Path()
            ml.move(to: CGPoint(x: 17, y: 44.5)); ml.addLine(to: CGPoint(x: 20, y: 44.5))
            ml.move(to: CGPoint(x: 28, y: 44.5)); ml.addLine(to: CGPoint(x: 31, y: 44.5))
            ctx.stroke(ml, with: .color(Tokens.inkSoftC),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round))

        case .asleep:
            ctx.fill(Path(ellipseIn: CGRect(x: 11, y: 33, width: 26, height: 10)),
                     with: .color(fill))
            seg(CGPoint(x: 19, y: 37), CGPoint(x: 23, y: 37), 1.4)
            seg(CGPoint(x: 26, y: 37), CGPoint(x: 30, y: 37), 1.4)

        case .stale:
            idleBody(0.85)
            seg(CGPoint(x: 18, y: 30), CGPoint(x: 22, y: 30), 1.5)
            seg(CGPoint(x: 26, y: 30), CGPoint(x: 30, y: 30), 1.5)

        case .empty:
            ctx.opacity = 0.8
            ctx.stroke(Path(ellipseIn: CGRect(x: 13, y: 34, width: 22, height: 8)),
                       with: .color(Tokens.calmC),
                       style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            ctx.opacity = 1
        }

        if input.isMany && !input.state.isException {
            let t = SettingsStore.shared.thresholds
            let others = input.sessions.compactMap { $0 }.sorted(by: >).dropFirst().prefix(2)
            let slots: [(CGFloat, CGFloat, CGFloat)] = [(36, 38, 5), (42, 31, 3.8)]
            for (i, pct) in others.enumerated() where i < slots.count {
                let (x, y, r) = slots[i]
                dot(x, y, r, t.state(for: pct).color)
                dot(x, y - 0.5, r * 0.22, ink)
            }
        }
    }
}

/// Bounces its content 4 pt. Freezes mid-jump when motion is disallowed — the
/// airborne pose plus motion lines already say "panicking".
struct BouncingLayer<Content: View>: View {
    let animates: Bool
    @ViewBuilder var content: Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animates)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = animates ? abs(sin(t * .pi / 0.9)) : 1
            content.offset(y: -4 * phase)
        }
    }
}
