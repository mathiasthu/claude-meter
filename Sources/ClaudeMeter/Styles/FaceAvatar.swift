import SwiftUI

/// 01 · Face — 44×44 pt, squircle r12.
///
/// The expression is the datum. Absence never borrows an expression: no-data
/// wears question-mark eyes rather than a calm face, so a face at rest always
/// means genuinely calm. Exceptions ride in corner badges so the face itself
/// never lies.
struct FaceAvatar: View {
    let input: AvatarInput

    var body: some View {
        ZStack {
            Canvas { ctx, _ in draw(&ctx) }
                .frame(width: 44, height: 44)
            // The critical badge is a separate layer so it can pulse without
            // re-rasterising the whole canvas every frame.
            if input.state == .critical {
                PulsingBadge(animates: input.animates) {
                    ZStack {
                        Circle().fill(Tokens.criticalC).frame(width: 13, height: 13)
                        Text("!").font(Typo.ui(9.5, .heavy)).foregroundColor(.white)
                    }
                }
                .offset(x: 14, y: -14)
            }
        }
        .frame(width: 44, height: 44)
    }

    private func draw(_ ctx: inout GraphicsContext) {
        let ink = AvatarInk(input.state)
        AvatarChrome.ground(&ctx, rect: CGRect(x: 1.5, y: 1.5, width: 41, height: 41),
                            radius: 12, ink: ink)

        let stroke = StrokeStyle(lineWidth: 2, lineCap: .round)
        func line(_ pts: [CGPoint]) {
            var p = Path()
            p.move(to: pts[0])
            pts.dropFirst().forEach { p.addLine(to: $0) }
            ctx.stroke(p, with: .color(ink.ink), style: stroke)
        }
        func arc(_ from: CGPoint, _ ctrl: CGPoint, _ to: CGPoint) {
            var p = Path()
            p.move(to: from)
            p.addQuadCurve(to: to, control: ctrl)
            ctx.stroke(p, with: .color(ink.ink), style: stroke)
        }
        func eye(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, filled: Bool = true) {
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            if filled { ctx.fill(Path(ellipseIn: rect), with: .color(ink.ink)) }
            else { ctx.stroke(Path(ellipseIn: rect), with: .color(ink.ink), lineWidth: 2) }
        }

        switch input.state {
        case .calm:
            arc(CGPoint(x: 11, y: 20), CGPoint(x: 15, y: 15), CGPoint(x: 19, y: 20))
            arc(CGPoint(x: 25, y: 20), CGPoint(x: 29, y: 15), CGPoint(x: 33, y: 20))
            arc(CGPoint(x: 17, y: 29), CGPoint(x: 22, y: 33), CGPoint(x: 27, y: 29))

        case .focused:
            eye(15, 19, 2.5); eye(29, 19, 2.5)
            line([CGPoint(x: 17, y: 30), CGPoint(x: 27, y: 30)])

        case .strained:
            line([CGPoint(x: 10, y: 13), CGPoint(x: 18, y: 16)])
            line([CGPoint(x: 34, y: 13), CGPoint(x: 26, y: 16)])
            eye(15, 20, 2); eye(29, 20, 2)
            var m = Path()
            m.move(to: CGPoint(x: 16, y: 30))
            m.addQuadCurve(to: CGPoint(x: 22, y: 30), control: CGPoint(x: 19, y: 27))
            m.addQuadCurve(to: CGPoint(x: 28, y: 30), control: CGPoint(x: 25, y: 33))
            ctx.stroke(m, with: .color(ink.ink), style: stroke)

        case .critical:
            eye(15, 19, 3, filled: false); eye(29, 19, 3, filled: false)
            ctx.fill(Path(ellipseIn: CGRect(x: 19, y: 26.5, width: 6, height: 8)),
                     with: .color(ink.ink))

        case .asleep:
            line([CGPoint(x: 11, y: 19), CGPoint(x: 19, y: 19)])
            line([CGPoint(x: 25, y: 19), CGPoint(x: 33, y: 19)])
            line([CGPoint(x: 19, y: 30), CGPoint(x: 25, y: 30)])
            AvatarChrome.zzz(&ctx, big: CGPoint(x: 35, y: 12),
                             small: CGPoint(x: 40, y: 7.5), ink: ink)

        case .stale:
            eye(15, 19, 2.5); eye(29, 19, 2.5)
            line([CGPoint(x: 17, y: 30), CGPoint(x: 27, y: 30)])
            AvatarChrome.clock(&ctx, at: CGPoint(x: 36, y: 36), ink: ink)

        case .noData:
            // Question marks where eyes would be: the face is visibly not
            // reporting rather than reporting "fine".
            AvatarChrome.text(&ctx, "?", at: CGPoint(x: 15, y: 19), size: 12,
                              color: ink.ink, weight: .bold)
            AvatarChrome.text(&ctx, "?", at: CGPoint(x: 29, y: 19), size: 12,
                              color: ink.ink, weight: .bold)
            line([CGPoint(x: 19, y: 31), CGPoint(x: 25, y: 31)])

        case .empty:
            break  // the dashed ground is the whole message
        }

        // Session-count pill, so several sessions cannot hide behind one face.
        if input.isMany && !input.state.isException {
            let badge = CGRect(x: 25, y: 31.5, width: 15, height: 10)
            let p = Path(roundedRect: badge, cornerRadius: 5, style: .continuous)
            ctx.fill(p, with: .color(ink.ground))
            ctx.stroke(p, with: .color(ink.hairline), lineWidth: 1)
            AvatarChrome.text(&ctx, "×\(input.sessions.count)",
                              at: CGPoint(x: 32.5, y: 36.5), size: 7,
                              color: Tokens.inkC, weight: .bold)
        }
    }
}

/// Scale-pulses its content when animation is allowed, and stands still when
/// it is not — the badge is the signal either way.
struct PulsingBadge<Content: View>: View {
    let animates: Bool
    @ViewBuilder var content: Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animates)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // 1.2 s ease-in-out, 1.0 → 1.15.
            let phase = animates ? (1 - cos(t * 2 * .pi / 1.2)) / 2 : 0
            content.scaleEffect(1 + 0.15 * phase)
        }
    }
}
