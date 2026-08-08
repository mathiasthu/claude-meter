import SwiftUI

/// 02 · Pill — 30 pt tall, minimum 96 pt wide, grows with its content.
///
/// Text-first, so a false number is worse here than a blank: when a limit is
/// missing the pill drops it and promotes the next real reading
/// ("no limits · ctx 45%") rather than printing 0%.
struct PillAvatar: View {
    let input: AvatarInput

    private var text: String { Self.caption(input) }

    var body: some View {
        HStack(spacing: 8) {
            glyph
            Text(text)
                .font(Typo.mono(11, input.state == .critical ? .semibold : .medium))
                .foregroundColor(textColor)
                .fixedSize()
        }
        .padding(.leading, 9)
        .padding(.trailing, 12)
        .frame(height: 30)
        .frame(minWidth: 96)
        .background(
            ZStack {
                Capsule().fill(Tokens.groundC)
                Capsule().strokeBorder(Tokens.hairlineC, lineWidth: 1)
            }
            .opacity(input.state == .empty ? 0.6 : 1)
        )
        .fixedSize()
    }

    private var textColor: Color {
        switch input.state {
        case .critical: return Tokens.criticalC
        case .asleep, .stale, .empty: return Tokens.calmC
        default: return Tokens.inkC
        }
    }

    /// The leading mark. Every variant is a different shape, not just a
    /// different colour, so escalation survives colour-vision deficiency.
    @ViewBuilder
    private var glyph: some View {
        switch input.state {
        case .critical:
            PulsingBadge(animates: input.animates) {
                ZStack {
                    Triangle().fill(Tokens.criticalC).frame(width: 15, height: 13)
                    Text("!").font(Typo.ui(8, .heavy)).foregroundColor(.white)
                        .offset(y: 2)
                }
            }
            .frame(width: 15)
        case .asleep, .empty:
            Circle().strokeBorder(Tokens.calmC, lineWidth: 1.6).frame(width: 7, height: 7)
        case .noData:
            Circle()
                .strokeBorder(Tokens.calmC, style: StrokeStyle(lineWidth: 1.4, dash: [2, 2]))
                .frame(width: 7, height: 7)
        default:
            if input.isMany {
                // Stacked dots, worst in front. Laid out left-to-right in
                // ascending severity so the worst lands nearest the numbers and
                // draws on top; the frame is wide enough for the whole fan,
                // which a trailing-aligned stack was clipping.
                ZStack(alignment: .leading) {
                    ForEach(Array(stackColors.enumerated()), id: \.offset) { i, c in
                        Circle().fill(c)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Tokens.groundC, lineWidth: 1.5))
                            .offset(x: CGFloat(i) * 3.5)
                    }
                }
                .frame(width: 8 + CGFloat(max(0, stackColors.count - 1)) * 3.5,
                       alignment: .leading)
            } else {
                Circle().fill(input.state.color).frame(width: 8, height: 8)
            }
        }
    }

    /// Up to three sessions, ascending severity. The worst is drawn last, so
    /// it sits on top of the fan and closest to the numbers.
    private var stackColors: [Color] {
        let t = SettingsStore.shared.thresholds
        return input.sessions
            .compactMap { $0 }
            .sorted(by: >)
            .prefix(3)
            .reversed()
            .map { t.state(for: $0).color }
    }

    /// Builds the caption from whatever data actually exists, degrading rather
    /// than inventing.
    static func caption(_ i: AvatarInput) -> String {
        switch i.state {
        case .empty:
            return "no sessions"
        case .asleep:
            if let five = i.fiveHour { return "idle · 5h \(Fmt.percent(five))" }
            return "idle"
        case .stale:
            let head = i.fiveHour.map { "5h \(Fmt.percent($0))" } ?? "last seen"
            let tail = i.age.map { " · \(Fmt.age($0)) ago" } ?? ""
            return head + tail
        case .noData:
            if let ctx = i.context { return "no limits · ctx \(Fmt.percent(ctx))" }
            return "no limit data"
        default:
            var parts: [String] = []
            if i.isMany { parts.append("×\(i.sessions.count)") }
            if let five = i.fiveHour {
                parts.append("5h \(Fmt.percent(five))")
                if let reset = Fmt.countdown(to: i.fiveHourResetsAt) { parts.append(reset) }
            } else if let ctx = i.context {
                parts.append("ctx \(Fmt.percent(ctx))")
            }
            return parts.isEmpty ? "—" : parts.joined(separator: " · ")
        }
    }
}

/// Warning triangle for the critical glyph — a shape cue that reads in
/// greyscale, which a coloured dot does not.
struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
