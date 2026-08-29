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
    /// Seconds between blinks in the critical state, from settings. Carried on
    /// the input rather than read from `SettingsStore.shared` inside the style,
    /// so the settings preview reflects the slider as it moves and the
    /// offscreen renderers stay independent of whatever the user has saved.
    var criticalBlinkSeconds: Double = 1.5
    /// The state this one replaced, and the moment it did, on
    /// `timeIntervalSinceReferenceDate`.
    ///
    /// A style that morphs between poses has to know where it is coming from,
    /// and a SwiftUI view cannot remember: styles are structs rebuilt on every
    /// update. So whoever derives the state records the change and passes it
    /// down. Both nil means "no history" — draw the state outright — which is
    /// what the settings preview wants while its slider sweeps and what the
    /// offscreen renderers need to capture a settled frame.
    var previousState: MeterState?
    var stateChangedAt: TimeInterval?
    /// When the avatar was last clicked, on `timeIntervalSinceReferenceDate`.
    ///
    /// A click already opens the breakdown; this is the sprite acknowledging
    /// that it was the thing you hit. Carried on the input for the same reason
    /// `stateChangedAt` is: the styles are structs rebuilt on every update and
    /// cannot remember anything themselves. Nil everywhere except the floating
    /// panel — the settings preview and the offscreen renderers have no clicks
    /// to report and must keep drawing settled frames.
    var clickedAt: TimeInterval?

    // Everything below is appended rather than filed beside the reading it
    // belongs to, and must stay that way. The memberwise initialiser is
    // positional, eight call sites pass labelled arguments in declaration
    // order, and Swift will not let them be out of order — so inserting
    // `sevenDayResetsAt` next to `sevenDay` is eight call sites to re-sort for
    // no gain. Appending with defaults leaves every one of them alone.

    var sevenDayResetsAt: Double?
    /// Whether the window these percentages came from has since rolled over.
    /// Read off the store rather than re-derived from the percentage: a window
    /// past its reset genuinely reads 0%, and the only way to tell that apart
    /// from a window that happens to be empty is to have been told.
    var fiveHourHasReset: Bool = false
    var sevenDayHasReset: Bool = false
    /// The session behind the context reading — the one that will need
    /// /compact first. Nil unless some live session actually reports a
    /// percentage, so a name and a token count can never appear beside a ring
    /// with no reading in it.
    var contextName: String?
    var contextModel: String?
    var contextTokens: Int?
    var contextSize: Int?
    /// The ramp boundaries this input is drawn against. Carried here so a style
    /// never reaches for `SettingsStore.shared`: that read is invisible to the
    /// settings preview and to the offscreen renderers, both of which hand
    /// styles an input the user's saved settings had no part in building.
    var thresholds: Thresholds = .default
    /// Which edge the docked strip is flush against.
    var notchEdge: NotchEdge = .right
    /// Which ring's breakdown is open. Nil everywhere except the floating
    /// panel — same contract, and same reason, as `clickedAt`.
    var selectedRing: NotchRing?
    /// How old the snapshot behind `contextName`/`contextTokens` is, which is
    /// not the same question `age` answers. `age` is the freshest snapshot
    /// across every session — the app's "are these numbers current at all"
    /// reading — while the context ring is looking at one particular session,
    /// and the two part company exactly when it matters: a session sitting in
    /// a long subagent run stops publishing a status line while a second,
    /// quieter session keeps updating, so the ring's 90% can be forty minutes
    /// old beside an `age` of ten seconds. Nil when no session is being named.
    var contextAge: TimeInterval?

    /// Three or more concurrent sessions switches styles to their multi
    /// variant. Two is common enough to be unremarkable.
    var isMany: Bool { sessions.count >= 3 }

    /// True when cycles are allowed to run at all. Reduce motion — the system
    /// setting, or the app's own checkbox — is the only thing that turns it
    /// off. Which states actually move is each style's own business, and every
    /// one of them asks about the state before it asks about this.
    var animates: Bool { motionAllowed }

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
