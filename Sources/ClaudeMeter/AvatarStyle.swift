import SwiftUI

/// The avatar styles the user can choose between.
///
/// An enum rather than a protocol with associated views: styles need to be
/// persisted by name, enumerated in the picker, and switched on at one call
/// site. Adding a style is a case, a size, and a view — nothing else changes.
enum AvatarStyleID: String, CaseIterable, Identifiable {
    case face
    case pill
    case pixelCreature
    case blobCreature

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .face:          return "Face"
        case .pill:          return "Pill"
        case .pixelCreature: return "Creature · pixel"
        case .blobCreature:  return "Creature · blob"
        }
    }

    var blurb: String {
        switch self {
        case .face:
            return "A companion, not an instrument. Learn the expressions once and never read a number again."
        case .pill:
            return "Maximum truth per pixel: the worst metric, its number, and its deadline in one row."
        case .pixelCreature:
            return "A blocky quadruped whose stance carries the state. Looks native next to a monospace prompt."
        case .blobCreature:
            return "The soft-bodied original. Same pose grammar: it works, sweats, panics and sleeps."
        }
    }

    /// Size at 1×, before the user's scale setting. The pill is the exception:
    /// it grows with its text, so this is only its minimum.
    var naturalSize: CGSize {
        switch self {
        case .face:          return CGSize(width: 44, height: 44)
        case .pill:          return CGSize(width: 128, height: 30)
        case .pixelCreature: return CGSize(width: 48, height: 48)
        case .blobCreature:  return CGSize(width: 48, height: 48)
        }
    }

    @ViewBuilder
    func view(_ input: AvatarInput) -> some View {
        switch self {
        case .face:          FaceAvatar(input: input)
        case .pill:          PillAvatar(input: input)
        case .pixelCreature: PixelCreatureAvatar(input: input)
        case .blobCreature:  BlobCreatureAvatar(input: input)
        }
    }
}

// MARK: - Shared drawing vocabulary

/// Colours resolved once per draw. Canvas cannot read the environment mid-draw,
/// so styles resolve what they need up front.
struct AvatarInk {
    let state: MeterState
    let ground: Color
    let hairline: Color
    let ink: Color
    let inkSoft: Color
    let dormant: Color
    /// Grey stand-in used by every exception state, so a stale or sleeping
    /// avatar can never be mistaken for a live reading.
    let greyed: Color

    init(_ state: MeterState) {
        self.state = state
        ground = Tokens.groundC
        hairline = Tokens.hairlineC
        inkSoft = Tokens.inkSoftC
        dormant = Tokens.dormantC
        greyed = Tokens.calmC
        // Asleep and stale drain the features to grey; the other exceptions
        // keep normal ink and signal through shape instead.
        ink = (state == .asleep || state == .stale) ? Tokens.calmC : Tokens.inkC
    }
}

enum AvatarChrome {

    /// The squircle or disc every style sits on. Critical swaps the hairline
    /// for a full-strength state ring; empty becomes a dashed outline with no
    /// fill, so "nothing here" is visibly not "something at zero".
    static func ground(_ ctx: inout GraphicsContext, rect: CGRect, radius: CGFloat,
                       ink: AvatarInk) {
        let path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        switch ink.state {
        case .empty:
            ctx.opacity = 0.6
            ctx.stroke(path, with: .color(ink.greyed),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ctx.opacity = 1
        case .critical:
            ctx.fill(path, with: .color(ink.ground))
            ctx.stroke(path, with: .color(Tokens.criticalC), lineWidth: 2)
        default:
            ctx.opacity = ink.state == .asleep ? 0.78 : 1
            ctx.fill(path, with: .color(ink.ground))
            ctx.stroke(path, with: .color(ink.hairline), lineWidth: 1)
            ctx.opacity = 1
        }
    }

    /// The stale mark: a small clock face. Used by every style, because "this
    /// was true a while ago" needs one symbol across the whole system.
    static func clock(_ ctx: inout GraphicsContext, at p: CGPoint, ink: AvatarInk) {
        let r: CGFloat = 5.5
        let dial = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.fill(dial, with: .color(ink.ground))
        ctx.stroke(dial, with: .color(ink.greyed), lineWidth: 1.2)
        var hands = Path()
        hands.move(to: CGPoint(x: p.x, y: p.y - 3))
        hands.addLine(to: p)
        hands.addLine(to: CGPoint(x: p.x + 2.4, y: p.y + 1.4))
        ctx.stroke(hands, with: .color(ink.greyed),
                   style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
    }

    /// Cobweb in the corner — the second half of the stale signal on the
    /// creature styles, where a grey body alone could read as a pose.
    static func cobweb(_ ctx: inout GraphicsContext, ink: AvatarInk) {
        var p = Path()
        let anchor = CGPoint(x: 46, y: 2)
        for end in [CGPoint(x: 36, y: 12), CGPoint(x: 40, y: 15), CGPoint(x: 33, y: 8)] {
            p.move(to: anchor); p.addLine(to: end)
        }
        p.move(to: CGPoint(x: 42.5, y: 5.5))
        p.addQuadCurve(to: CGPoint(x: 37.5, y: 10.5), control: CGPoint(x: 41, y: 9))
        p.move(to: CGPoint(x: 44.5, y: 3.5))
        p.addQuadCurve(to: CGPoint(x: 35, y: 10), control: CGPoint(x: 42.5, y: 8.5))
        ctx.stroke(p, with: .color(ink.greyed), lineWidth: 0.9)
    }

    /// Sleep marks. Two sizes so they read as drifting upward.
    static func zzz(_ ctx: inout GraphicsContext, big: CGPoint, small: CGPoint, ink: AvatarInk) {
        ctx.draw(Text("z").font(Typo.ui(9, .bold)).foregroundColor(ink.inkSoft), at: big)
        ctx.draw(Text("z").font(Typo.ui(6.5, .bold)).foregroundColor(ink.inkSoft), at: small)
    }

    static func text(_ ctx: inout GraphicsContext, _ s: String, at p: CGPoint,
                     size: CGFloat, color: Color, weight: Font.Weight = .semibold,
                     mono: Bool = false) {
        let font = mono ? Typo.mono(size, .semibold) : Typo.ui(size, weight)
        ctx.draw(Text(s).font(font).foregroundColor(color), at: p)
    }
}

/// Reports its subview's intrinsic size multiplied by `scale`.
///
/// `scaleEffect` renders larger without changing the layout box, and framing
/// to `naturalSize` instead is wrong for the pill, which grows with its text —
/// that combination clipped it. This measures what the style actually wants
/// and claims exactly that much room, scaled.
struct ScaledLayout: Layout {
    var scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let natural = first.sizeThatFits(.unspecified)
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        let natural = first.sizeThatFits(.unspecified)
        // Placed at natural size and centred; the subview's own scaleEffect
        // does the growing, anchored on the same centre.
        first.place(at: CGPoint(x: bounds.midX, y: bounds.midY),
                    anchor: .center, proposal: ProposedViewSize(natural))
    }
}

/// A wrapper that applies the user's scale and opacity and keeps the layout
/// box honest, so the panel can size itself to whatever style is selected.
struct ScaledAvatar: View {
    let style: AvatarStyleID
    let input: AvatarInput
    var scale: Double = 1
    var opacity: Double = 1

    var body: some View {
        ScaledLayout(scale: scale) {
            style.view(input).scaleEffect(scale)
        }
        .opacity(opacity)
        .fixedSize()
    }
}
