import Foundation

// Mirrors the snapshot written by bin/claude-meter-collect. The collector
// normalizes Claude Code's status line JSON, so anything genuinely optional
// upstream is optional here too:
//
//   - rate_limits is absent entirely for non-subscribers, and for any session
//     that has not yet had an API response come back.
//   - context.used_percentage is null early in a session and again right after
//     /compact, until the next API call repopulates it.

struct Snapshot: Decodable {
    let ts: Double
    let sessionId: String
    let sessionName: String?
    let cwd: String?
    let model: String?
    let effort: String?
    let fastMode: Bool?
    let context: ContextInfo
    let cost: CostInfo
    let rateLimits: RateLimits?

    struct ContextInfo: Decodable {
        let usedPercentage: Double?
        let remainingPercentage: Double?
        let totalInputTokens: Int?
        let totalOutputTokens: Int?
        let size: Int?
    }

    struct CostInfo: Decodable {
        let totalCostUsd: Double?
        let totalDurationMs: Double?
    }

    struct RateLimits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?

        struct Window: Decodable {
            let usedPercentage: Double?
            let resetsAt: Double?
        }
    }
}

// MARK: - Derived

extension Snapshot {
    var age: TimeInterval { max(0, Date().timeIntervalSince1970 - ts) }

    /// A session whose status line fired recently. The status line does not
    /// refresh while a session sits idle, so this is "recently active", not
    /// "still open" -- the SessionEnd hook is what removes closed sessions.
    var isLive: Bool { age < Liveness.live }

    /// Past this the numbers are old enough to be misleading, so the UI shows
    /// them greyed with an age rather than presenting them as current.
    var isStale: Bool { age >= Liveness.stale }

    enum Liveness {
        static let live: TimeInterval = 5 * 60
        static let stale: TimeInterval = 60 * 60
    }

    /// What to call this session in the list. Prefers the session's own name,
    /// falls back to the directory it is working in.
    var displayName: String {
        if let n = sessionName, !n.isEmpty { return n }
        guard let cwd, !cwd.isEmpty else { return "session" }
        if cwd == NSHomeDirectory() { return "~" }
        return (cwd as NSString).lastPathComponent
    }
}
