import SwiftUI

/// The avatar's expression, and the single place thresholds are defined --
/// the menubar tint, the bars in the popover, and the face all read from here
/// so they can never disagree about what counts as "red".
///
/// These match the collector's HUD line colors (bin/claude-meter-collect).
enum Mood {
    case calm       // < 50%
    case focused    // 50-70%
    case sweating   // 70-85%
    case alarmed    // >= 85%
    case asleep     // no live session
    case stale      // live sessions, but the numbers are old or never arrived

    init(percentage: Double) {
        switch percentage {
        case ..<50:  self = .calm
        case ..<70:  self = .focused
        case ..<85:  self = .sweating
        default:     self = .alarmed
        }
    }

    var face: String {
        switch self {
        case .calm:     return "◕‿◕"
        case .focused:  return "◔_◔"
        case .sweating: return "◕﹏◕"
        case .alarmed:  return "◉益◉"
        case .asleep:   return "-_-"
        case .stale:    return "?_?"
        }
    }

    var color: Color {
        switch self {
        case .calm:     return Palette.green
        case .focused:  return Palette.teal
        case .sweating: return Palette.amber
        case .alarmed:  return Palette.red
        case .asleep:   return Palette.dim
        case .stale:    return Palette.dim
        }
    }

    var label: String {
        switch self {
        case .calm:     return "Plenty of runway"
        case .focused:  return "Pacing matters"
        case .sweating: return "Getting tight"
        case .alarmed:  return "Wind down"
        case .asleep:   return "No live session"
        case .stale:    return "Waiting for data"
        }
    }

    /// Only the top state animates. A widget that is always moving stops being
    /// glanceable, and the point of the pulse is that it means something.
    var pulses: Bool { self == .alarmed }
}

enum Palette {
    static let green = Color(red: 0.30, green: 0.78, blue: 0.45)
    static let teal  = Color(red: 0.25, green: 0.70, blue: 0.72)
    static let amber = Color(red: 0.95, green: 0.68, blue: 0.20)
    static let red   = Color(red: 0.92, green: 0.31, blue: 0.29)
    static let dim   = Color.secondary

    static func tint(for percentage: Double?) -> Color {
        guard let percentage else { return dim }
        return Mood(percentage: percentage).color
    }
}

// MARK: - Formatting

enum Fmt {
    /// 185512 -> "186k", 1000000 -> "1M". Keeps the HUD and the popover
    /// speaking the same units as the collector's status line.
    static func tokens(_ n: Int?) -> String {
        guard let n else { return "—" }
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            // "1M" reads better than "1.0M" for the exact extended-context
            // size, which is the value this branch almost always sees.
            if m >= 10 || m == m.rounded() { return "\(Int(m.rounded()))M" }
            return String(format: "%.1fM", m)
        }
        if n >= 1000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        return "\(n)"
    }

    static func percent(_ p: Double?) -> String {
        guard let p else { return "—" }
        return "\(Int(p.rounded()))%"
    }

    /// Time until a rate limit window resets. Returns nil once it has elapsed
    /// -- a negative countdown is worse than no countdown.
    static func countdown(to epoch: Double?) -> String? {
        guard let epoch else { return nil }
        let secs = Int(epoch - Date().timeIntervalSince1970)
        guard secs > 0 else { return nil }
        let h = secs / 3600, m = (secs % 3600) / 60
        return h > 0 ? String(format: "%dh%02dm", h, m) : "\(m)m"
    }

    /// How long ago a snapshot was published, for the stale indicator.
    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    static func usd(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "$%.2f", v)
    }
}
