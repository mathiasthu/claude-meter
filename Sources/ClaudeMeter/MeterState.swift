import SwiftUI

/// The state an avatar renders. Four escalation levels plus four exceptions.
///
/// The exceptions exist because absence is not zero and old is not current: a
/// missing rate limit drawn as an empty 0% bar tells the user the opposite of
/// the truth, and a stale reading drawn as a live one is worse than no reading.
enum MeterState: String, CaseIterable, Identifiable {
    case calm, focused, strained, critical
    case asleep      // no session active recently
    case stale       // data older than the stale window
    case noData      // rate limits have never arrived
    case empty       // no sessions at all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .calm:     return "Calm"
        case .focused:  return "Focused"
        case .strained: return "Strained"
        case .critical: return "Critical"
        case .asleep:   return "Asleep"
        case .stale:    return "Stale"
        case .noData:   return "No data"
        case .empty:    return "Empty"
        }
    }

    var headline: String {
        switch self {
        case .calm:     return "Plenty of runway"
        case .focused:  return "Pacing matters"
        case .strained: return "Getting tight"
        case .critical: return "Wind down"
        case .asleep:   return "No live session"
        case .stale:    return "Data is old"
        case .noData:   return "No limit data yet"
        case .empty:    return "Nothing running"
        }
    }

    /// Exceptions all render in the dormant grey. Nothing that is not a current
    /// reading is ever allowed a live colour.
    var isException: Bool {
        switch self {
        case .calm, .focused, .strained, .critical: return false
        default: return true
        }
    }

    var color: Color {
        switch self {
        case .calm:     return Tokens.calmC
        case .focused:  return Tokens.focusedC
        case .strained: return Tokens.strainedC
        case .critical: return Tokens.criticalC
        default:        return Tokens.dormantC
        }
    }

    /// Only the top state animates, and every animation has a still fallback.
    var animates: Bool { self == .critical }
}

/// Everything a style needs to draw itself. Styles are pure functions of this.
struct AvatarInput {
    var state: MeterState = .empty
    /// The value that produced `state`, for styles that show a number.
    var percentage: Double?
    var fiveHour: Double?
    var fiveHourResetsAt: Double?
    var sevenDay: Double?
    var context: Double?
    /// Per-session context fill, newest first. Drives the "many" treatment —
    /// with several sessions running, one hot session must not be able to hide
    /// inside an average.
    var sessions: [Double?] = []
    /// Seconds since this data was published, when that is worth showing.
    var age: TimeInterval?
    /// False when the system (or the user) has asked for reduced motion.
    var motionAllowed: Bool = true
    /// Whether to draw the plate each style normally sits on. Off by default:
    /// at avatar size the plate reads as a card with a picture in it rather
    /// than as the character itself. With it off the styles get a drop shadow
    /// instead, which is what keeps them legible over pale wallpaper.
    var showsBackground: Bool = false

    /// Three or more concurrent sessions switches styles to their multi
    /// variant. Two is common enough to be unremarkable.
    var isMany: Bool { sessions.count >= 3 }

    var animates: Bool { state.animates && motionAllowed }

    /// Colour for an arbitrary reading using the caller's thresholds.
    static func ramp(_ pct: Double?, _ t: Thresholds) -> Color {
        guard let pct else { return Tokens.dormantC }
        return t.state(for: pct).color
    }
}

/// User-editable escalation boundaries. Styles must encode state with a
/// continuous channel (arc length, size, needle angle, pose) as well as the
/// ramp colour, so nothing reads correctly only at the default 50/70/85.
struct Thresholds: Equatable, Codable {
    var focused: Double = 50
    var strained: Double = 70
    var critical: Double = 85
    /// Idle time before the avatar falls asleep, in seconds.
    var asleepAfter: TimeInterval = 5 * 60

    static let `default` = Thresholds()

    func state(for pct: Double) -> MeterState {
        if pct >= critical { return .critical }
        if pct >= strained { return .strained }
        if pct >= focused  { return .focused }
        return .calm
    }

    /// Keeps the three boundaries ordered after an edit by pushing neighbours
    /// rather than rejecting the input — raising Focused past Strained moves
    /// Strained up, which is what the person dragging clearly meant.
    mutating func set(_ key: Key, to raw: Double) {
        let v = min(100, max(0, raw.rounded()))
        switch key {
        case .focused:
            focused = v
            strained = max(strained, v)
            critical = max(critical, strained)
        case .strained:
            strained = v
            focused = min(focused, v)
            critical = max(critical, v)
        case .critical:
            critical = v
            strained = min(strained, v)
            focused = min(focused, strained)
        }
    }

    enum Key { case focused, strained, critical }
}
