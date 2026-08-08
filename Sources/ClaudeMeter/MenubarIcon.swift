import AppKit

/// The 16×16 menubar mark: a progress ring with a short stem.
///
/// The stem is what keeps it from reading as a system icon — a bare ring in
/// the menubar looks like something macOS put there. Ink follows the menubar's
/// own label colour so it works in both appearances; the state colour is
/// carried only by the progress arc.
enum MenubarIcon {

    static func image(state: MeterState, percentage: Double?, thresholds: Thresholds) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        // The drawing handler runs at draw time in the destination context, so
        // labelColor resolves against the menubar's current appearance rather
        // than whatever was current when the image was built.
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            draw(ctx, state: state, percentage: percentage, thresholds: thresholds)
            return true
        }
        image.accessibilityDescription = accessibilityLabel(state, percentage)
        return image
    }

    private static let center = CGPoint(x: 8, y: 7.5)
    private static let radius: CGFloat = 5.2
    private static let lineWidth: CGFloat = 1.8

    private static func draw(_ ctx: CGContext, state: MeterState,
                             percentage: Double?, thresholds: Thresholds) {
        let ink = NSColor.labelColor

        // Track. Dashed when no reading has ever arrived, so "missing" is
        // visible before you read any number.
        ctx.saveGState()
        ctx.setLineWidth(lineWidth)
        ctx.setStrokeColor(ink.withAlphaComponent(0.28).cgColor)
        if state == .noData { ctx.setLineDash(phase: 0, lengths: [2, 2]) }
        ctx.addPath(arcPath(fraction: 1))
        ctx.strokePath()
        ctx.restoreGState()

        // Progress arc, in the state colour. Exceptions never get a live
        // colour: stale draws its last reading in grey rather than pretending.
        if let pct = percentage, !state.isException || state == .stale {
            let color: NSColor = state == .stale
                ? Tokens.dormant
                : nsColor(for: thresholds.state(for: pct))
            ctx.saveGState()
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(color.cgColor)
            ctx.addPath(arcPath(fraction: min(1, max(0, pct / 100))))
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Stem.
        ctx.saveGState()
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(ink.withAlphaComponent(0.6).cgColor)
        ctx.move(to: CGPoint(x: 8, y: 13.2))
        ctx.addLine(to: CGPoint(x: 8, y: 15.2))
        ctx.strokePath()
        ctx.restoreGState()

        switch state {
        case .critical:
            // Shape cue inside the ring, so critical survives greyscale.
            glyph("!", size: 9, weight: .heavy, color: ink, at: CGPoint(x: 8, y: 7.6))
        case .stale:
            ctx.saveGState()
            ctx.setLineWidth(1)
            ctx.setStrokeColor(ink.withAlphaComponent(0.5).cgColor)
            ctx.addEllipse(in: CGRect(x: center.x - 1.4, y: center.y - 1.4,
                                      width: 2.8, height: 2.8))
            ctx.strokePath()
            ctx.restoreGState()
        case .asleep, .empty:
            glyph("–", size: 9, weight: .semibold,
                  color: ink.withAlphaComponent(0.55), at: CGPoint(x: 8, y: 7.6))
        default:
            break
        }
    }

    /// Points computed directly rather than via `addArc`, whose direction flag
    /// inverts in a flipped context — this is unambiguous in either.
    private static func arcPath(fraction: Double) -> CGPath {
        let path = CGMutablePath()
        let steps = max(2, Int(64 * fraction))
        for i in 0...steps {
            let theta = 2 * Double.pi * fraction * Double(i) / Double(steps)
            let p = CGPoint(x: center.x + radius * sin(theta),
                            y: center.y - radius * cos(theta))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private static func glyph(_ s: String, size: CGFloat, weight: NSFont.Weight,
                              color: NSColor, at p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let bounds = str.size()
        str.draw(at: CGPoint(x: p.x - bounds.width / 2, y: p.y - bounds.height / 2))
    }

    private static func nsColor(for state: MeterState) -> NSColor {
        switch state {
        case .calm:     return Tokens.calm
        case .focused:  return Tokens.focused
        case .strained: return Tokens.strained
        case .critical: return Tokens.critical
        default:        return Tokens.dormant
        }
    }

    private static func accessibilityLabel(_ state: MeterState, _ pct: Double?) -> String {
        guard !state.isException, let pct else { return state.headline }
        return "\(Int(pct.rounded())) percent used — \(state.label)"
    }
}
