import SwiftUI

/// Which of the three readings a ring shows. Ordered top to bottom, which is
/// also the order `NotchData.readings` returns them and the order every
/// position on the strip is indexed by.
enum NotchRing: String, CaseIterable, Identifiable {
    case fiveHour, sevenDay, context

    var id: String { rawValue }

    /// The two or three characters printed inside the ring.
    var tag: String {
        switch self {
        case .fiveHour: return "5H"
        case .sevenDay: return "7D"
        case .context:  return "CTX"
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Which screen edge the strip is docked to. The strip is authored for the
/// right edge and reflected for the left.
enum NotchEdge: String, CaseIterable, Identifiable, Codable {
    case right, left

    var id: String { rawValue }

    var label: String { self == .right ? "Right" : "Left" }
}

/// The strip's geometry, authored once at 100% and multiplied on the way out.
///
/// Nothing outside this file reads a raw number: every accessor takes the
/// scale, for the reason `PillAvatar` takes it on its own metrics rather than
/// magnifying its output (`PillAvatar.swift:14-19`). The strip is type, strokes
/// and a hairline, none of which survive being rasterised at 76 pt and
/// resampled. The cost of that choice is that a single number which forgets to
/// be multiplied is invisible at 100% and obvious at 150%, so there is one
/// multiply site per number and it is here.
///
/// The ring centres come out at 70/162/254. The canvas authored them at
/// 71/165/259, which do not agree with its own flexbox; deriving them from the
/// box model is within 5 pt, self-consistent, and survives a change to the
/// label font.
enum NotchMetrics {

    // Authored at 100%. `NotchShape` is the only consumer allowed to read these
    // directly — it lays its path out in this space and scales it into whatever
    // rect it is handed.
    fileprivate static let w: CGFloat = 76
    fileprivate static let h: CGFloat = 344
    /// The concave flare at each end, where the strip meets the screen edge.
    fileprivate static let fillet: CGFloat = 22
    /// The two rounded corners on the inner edge.
    fileprivate static let corner: CGFloat = 26
    fileprivate static let bodyTop: CGFloat = 22
    fileprivate static let bodyHeight: CGFloat = 300
    fileprivate static let ringD: CGFloat = 46
    fileprivate static let ringR: CGFloat = 19
    fileprivate static let ringW: CGFloat = 4
    fileprivate static let gap: CGFloat = 6
    /// A 12 pt mono line box.
    fileprivate static let labelH: CGFloat = 14
    fileprivate static let itemH: CGFloat = ringD + gap + labelH          // 66
    fileprivate static let stackGap: CGFloat = 26
    fileprivate static let columnH: CGFloat = 3 * itemH + 2 * stackGap    // 250
    fileprivate static let columnTop: CGFloat = bodyTop + (bodyHeight - columnH) / 2   // 47

    /// The strip at 100%, for `AvatarStyleID.naturalSize`.
    static let naturalSize = CGSize(width: w, height: h)

    static func width(scale s: CGFloat) -> CGFloat { w * s }
    static func height(scale s: CGFloat) -> CGFloat { h * s }
    static func size(scale s: CGFloat) -> CGSize {
        CGSize(width: w * s, height: h * s)
    }

    static func ringDiameter(scale s: CGFloat) -> CGFloat { ringD * s }
    static func ringRadius(scale s: CGFloat) -> CGFloat { ringR * s }
    static func ringStroke(scale s: CGFloat) -> CGFloat { ringW * s }
    /// The disc drawn under a selected ring. Exactly the ring's own box, so the
    /// selection never widens the column.
    static func haloDiameter(scale s: CGFloat) -> CGFloat { ringD * s }
    static func labelGap(scale s: CGFloat) -> CGFloat { gap * s }
    /// Ring plus its label — the box a whole reading occupies, and the box a
    /// tap target covers.
    static func itemHeight(scale s: CGFloat) -> CGFloat { itemH * s }

    /// Top of reading `i`'s box, from the top of the strip.
    static func itemTop(_ i: Int, scale s: CGFloat) -> CGFloat {
        (columnTop + CGFloat(i) * (itemH + stackGap)) * s
    }

    /// Centre of reading `i`'s ring — 70, 162, 254 at 100%. What the popover's
    /// arrow points at, so `AvatarPanel` and the strip must derive it from the
    /// same arithmetic rather than from a centring pass.
    static func ringCentreY(_ i: Int, scale s: CGFloat) -> CGFloat {
        itemTop(i, scale: s) + ringD / 2 * s
    }

    /// Centre of reading `i`'s whole box, ring and label together.
    static func itemCentreY(_ i: Int, scale s: CGFloat) -> CGFloat {
        itemTop(i, scale: s) + itemH / 2 * s
    }
}

/// The strip's outline: a flat docked edge, two rounded corners on the inner
/// edge, and a concave fillet at each end where the strip flares out to meet
/// the screen.
///
/// Authored with x = 76 as the docked edge, so unmirrored is a right dock and a
/// left dock is the same path reflected about the rect's midline. Points are
/// computed rather than handed to `Path.addArc` for the reason
/// `MenubarIcon.arcPath` computes its own (`MenubarIcon.swift:89-90`): the
/// direction flag inverts in a flipped context. Here the stakes are higher than
/// there — the two fillets are the arcs whose centres lie *outside* the filled
/// region, and a flag the wrong way round turns them into bulges rather than
/// into a compile error.
struct NotchShape: Shape {
    var edge: NotchEdge = .right

    func path(in rect: CGRect) -> Path {
        let m = NotchMetrics.self
        var p = Path()

        p.move(to: point(m.w, 0, rect))
        sweep(&p, CGPoint(x: m.w - m.fillet, y: 0), m.fillet, 0, .pi / 2, rect)
        p.addLine(to: point(m.corner, m.bodyTop, rect))
        sweep(&p, CGPoint(x: m.corner, y: m.bodyTop + m.corner), m.corner, -.pi / 2, -.pi, rect)
        p.addLine(to: point(0, m.h - m.bodyTop - m.corner, rect))
        sweep(&p, CGPoint(x: m.corner, y: m.h - m.bodyTop - m.corner), m.corner, .pi, .pi / 2, rect)
        p.addLine(to: point(m.w - m.fillet, m.h - m.bodyTop, rect))
        sweep(&p, CGPoint(x: m.w - m.fillet, y: m.h), m.fillet, -.pi / 2, 0, rect)
        p.closeSubpath()
        return p
    }

    /// Authored coordinates into the rect, reflecting for a left dock.
    private func point(_ x: CGFloat, _ y: CGFloat, _ rect: CGRect) -> CGPoint {
        let mirrored = edge == .right ? x : NotchMetrics.w - x
        return CGPoint(x: rect.minX + mirrored * rect.width / NotchMetrics.w,
                       y: rect.minY + y * rect.height / NotchMetrics.h)
    }

    /// A quarter arc as line segments, angles measured in the y-down space
    /// `Path` uses. The first point coincides with the current point, so the
    /// leading segment is a no-op and the join is exact.
    private func sweep(_ p: inout Path, _ centre: CGPoint, _ radius: CGFloat,
                       _ from: CGFloat, _ to: CGFloat, _ rect: CGRect) {
        let steps = 16
        for i in 0...steps {
            let t = from + (to - from) * CGFloat(i) / CGFloat(steps)
            p.addLine(to: point(centre.x + radius * cos(t), centre.y + radius * sin(t), rect))
        }
    }
}
