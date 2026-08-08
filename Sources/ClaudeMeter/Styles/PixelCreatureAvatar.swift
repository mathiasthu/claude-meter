import SwiftUI

/// 03 · Creature — pixel. 48×48 pt, drawn on a 3 pt grid.
///
/// The grid is the point: state changes read as whole-pixel jumps rather than
/// smooth morphs, which keeps the character legible at 1× and makes it feel
/// like it belongs to the terminal it is watching. Body is brand orange at
/// rest — only escalation re-tints it, so orange means "fine".
struct PixelCreatureAvatar: View {
    let input: AvatarInput

    // 3 pt units at 1×, so pixels stay whole at 1× and 2×.
    private static let u: CGFloat = 3
    private static let ox: CGFloat = 6
    private static let oy: CGFloat = 9
    /// Features are fixed dark on a coloured body, in both appearances —
    /// flipping them to white in dark mode would erase them on the orange.
    private static let featureInk = Color(nsColor: NSColor(hex: 0x1D1D1F))

    var body: some View {
        ZStack {
            Canvas { ctx, _ in draw(&ctx) }.frame(width: 48, height: 48)
            if input.state == .critical {
                // Hops one grid unit in steps, not a smooth bounce — whole
                // pixel frames only.
                HoppingLayer(animates: input.animates, unit: Self.u) {
                    Canvas { ctx, _ in drawBody(&ctx) }.frame(width: 48, height: 48)
                }
            }
        }
        .frame(width: 48, height: 48)
    }

    private func px(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: Self.ox + x * Self.u, y: Self.oy + y * Self.u,
               width: w * Self.u, height: h * Self.u)
    }

    private var bodyFill: Color {
        switch input.state {
        case .strained: return Tokens.strainedC
        case .critical: return Tokens.criticalC
        case .asleep:   return Tokens.calmC
        case .stale:    return Color(nsColor: NSColor(hex: 0x98989D))
        case .empty:    return .clear
        default:        return Tokens.brandOrangeC
        }
    }

    private func draw(_ ctx: inout GraphicsContext) {
        let ink = AvatarInk(input.state, showsBackground: input.showsBackground)
        AvatarChrome.ground(&ctx, rect: CGRect(x: 1.5, y: 1.5, width: 45, height: 45),
                            radius: 14, ink: ink)
        // The critical pose is drawn by the animated layer instead, so the two
        // never double up.
        if input.state != .critical { drawBody(&ctx) }

        switch input.state {
        case .asleep:
            AvatarChrome.zzz(&ctx, big: CGPoint(x: 35, y: 22),
                             small: CGPoint(x: 39.5, y: 15.5), ink: ink)
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

    /// The creature itself, without the ground or the corner marks.
    private func drawBody(_ ctx: inout GraphicsContext) {
        let fill = bodyFill
        let ink = Self.featureInk
        func rect(_ r: CGRect, _ c: Color) { ctx.fill(Path(r), with: .color(c)) }

        /// Standing pose: body, two arms, four legs. Eyes are optional because
        /// calm wears sunglasses over them.
        func idle(dy: CGFloat = 0, eyeDx: CGFloat = 0, eyes: Bool = true) {
            rect(px(2, -1 + dy, 8, 6), fill)
            rect(px(0, 1.5 + dy, 2, 2), fill)
            rect(px(10, 1.5 + dy, 2, 2), fill)
            for x in [CGFloat(2), 4, 7, 9] { rect(px(x, 5 + dy, 1, 2.5), fill) }
            if eyes {
                rect(px(4 + eyeDx, 0.3 + dy, 1.3, 1.3), ink)
                rect(px(6.7 + eyeDx, 0.3 + dy, 1.3, 1.3), ink)
            }
        }

        switch input.state {
        case .calm:
            idle(eyes: false)
            // Sunglasses: nothing to see here.
            rect(px(3.5, 0.3, 2.3, 1.5), ink)
            rect(px(6.3, 0.3, 2.3, 1.5), ink)
            rect(px(5.8, 0.5, 0.5, 0.5), ink)   // bridge
            rect(px(2.7, 0.4, 0.8, 0.45), ink)  // temples
            rect(px(8.6, 0.4, 0.8, 0.45), ink)

        case .focused:
            idle()

        case .noData:
            idle(eyeDx: -0.5)

        case .strained:
            // Squashed silhouette, gritted teeth, sweat pixels.
            rect(px(1, 1.5, 10, 4.5), fill)
            rect(px(-0.5, 3, 2, 2), fill)
            rect(px(10.5, 3, 2, 2), fill)
            rect(px(1, 6, 1, 2), fill); rect(px(3, 6, 1, 1.6), fill)
            rect(px(7, 6, 1, 2), fill); rect(px(10, 6, 1, 1.6), fill)
            rect(px(2.9, 2.1, 1.7, 0.5), ink)   // brows
            rect(px(7.4, 2.1, 1.7, 0.5), ink)
            rect(px(3.4, 2.9, 1.3, 1.3), ink)
            rect(px(7.3, 2.9, 1.3, 1.3), ink)
            rect(px(11.3, -0.5, 1, 1), Tokens.calmC)
            rect(px(11.7, 0.9, 0.7, 0.7), Tokens.calmC)

        case .critical:
            // Airborne: arms up, legs dangling, eyes wide.
            rect(px(2, -1, 8, 6), fill)
            rect(px(0, 1.5, 2, 2), fill); rect(px(10, 1.5, 2, 2), fill)
            for x in [CGFloat(2), 4, 7, 9] { rect(px(x, 5, 1, 2.5), fill) }
            rect(px(3.4, 0, 2, 2), .white); rect(px(6.6, 0, 2, 2), .white)
            rect(px(4, 0.5, 0.9, 0.9), ink); rect(px(7.2, 0.5, 0.9, 0.9), ink)

        case .asleep:
            rect(px(1, 6.5, 10, 3), fill)
            rect(px(3.5, 7.4, 1.4, 0.45), ink)
            rect(px(7, 7.4, 1.4, 0.45), ink)

        case .stale:
            idle(eyes: false)
            // Hollow eyes: the lights are on but nothing is reporting.
            for x in [CGFloat(4), 6.7] {
                ctx.stroke(Path(px(x, 0.3, 1.3, 1.3)), with: .color(ink), lineWidth: 1)
            }

        case .empty:
            ctx.opacity = 0.8
            ctx.stroke(Path(px(2, -1, 8, 6)), with: .color(Tokens.calmC),
                       style: StrokeStyle(lineWidth: 1.1, dash: [3, 3]))
            ctx.opacity = 1
        }

        // Mini creatures for the extra sessions, each tinted by its own
        // reading, so a hot session cannot hide behind a calm leader.
        if input.isMany && !input.state.isException {
            drawCompanions(&ctx, ink: ink)
        }
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

/// Steps its content up by one grid unit and back, on whole frames. Still —
/// and airborne — when animation is not allowed, because the pose alone
/// already reads as panic.
struct HoppingLayer<Content: View>: View {
    let animates: Bool
    let unit: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.45, paused: !animates)) { timeline in
            let step = Int(timeline.date.timeIntervalSinceReferenceDate / 0.45) % 2
            content.offset(y: (animates && step == 0) ? -unit : 0)
        }
    }
}
