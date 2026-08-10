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
    /// Path to the session's transcript, recorded by the collector so the app
    /// can ask the filesystem when this session last did anything. Optional
    /// because snapshots written before this field existed are still on disk.
    let transcript: String?

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
    /// How old the *numbers* are. Everything the UI prints comes from the
    /// snapshot, so this is what decides whether they can be shown as current.
    var age: TimeInterval { max(0, Date().timeIntervalSince1970 - ts) }

    /// How long since the session last did anything, which is not the same
    /// question and used to be answered with the same number.
    ///
    /// The status line fires on assistant messages. A session that dispatches
    /// a subagent stops producing them while the subagent works, so its
    /// snapshot goes minutes or hours out of date while the session is very
    /// much alive — observed at over three hours on a session whose transcript
    /// had been written to eighteen minutes earlier. Reading that as "asleep"
    /// was the single most wrong thing the avatar did.
    ///
    /// The transcript keeps growing throughout, so its mtime is the honest
    /// activity signal. Falls back to the snapshot for anything written before
    /// the collector recorded the path, or if the file has since gone.
    var activityAge: TimeInterval {
        guard let transcript,
              let touched = try? FileManager.default
                .attributesOfItem(atPath: transcript)[.modificationDate] as? Date
        else { return age }
        return min(age, max(0, Date().timeIntervalSince(touched)))
    }

    /// A session that has done something recently — including work that never
    /// reaches the status line. Closed sessions are removed by the SessionEnd
    /// hook rather than detected here.
    var isLive: Bool { activityAge < Liveness.live }

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
