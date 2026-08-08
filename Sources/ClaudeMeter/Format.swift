import Foundation

/// Number and time formatting, in one place so the menubar, the avatar and the
/// dropdown can never disagree about how the same value reads.
///
/// House rules from the spec: percentages are always whole numbers, countdowns
/// are minute-precision, and nothing invents a value it does not have.
enum Fmt {

    /// 185512 -> "186k", 1000000 -> "1M".
    static func tokens(_ n: Int?) -> String {
        guard let n else { return "—" }
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            if m >= 10 || m == m.rounded() { return "\(Int(m.rounded()))M" }
            return String(format: "%.1fM", m)
        }
        if n >= 1000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        return "\(n)"
    }

    /// "247k / 1M". Absent capacity still shows the used side.
    static func tokenPair(_ used: Int?, _ capacity: Int?) -> String {
        guard used != nil || capacity != nil else { return "—" }
        return "\(tokens(used)) / \(tokens(capacity))"
    }

    /// No decimal places, ever — fake precision on a number that moves in
    /// whole units is noise.
    static func percent(_ p: Double?) -> String {
        guard let p else { return "—" }
        return "\(Int(p.rounded()))%"
    }

    /// Compact countdown for tight surfaces: "3h07m", "41m", "4d02h".
    /// Returns nil once elapsed — a negative countdown is worse than none.
    static func countdown(to epoch: Double?, spaced: Bool = false) -> String? {
        guard let epoch else { return nil }
        let secs = Int(epoch - Date().timeIntervalSince1970)
        guard secs > 0 else { return nil }
        let gap = spaced ? " " : ""
        let d = secs / 86_400, h = (secs % 86_400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return String(format: "%dd%@%02dh", d, gap, h) }
        if h > 0 { return String(format: "%dh%@%02dm", h, gap, m) }
        return "\(m)m"
    }

    /// How long ago something was published. Used wherever a countdown would
    /// otherwise imply the data is live.
    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h \(( s % 3600) / 60)m" }
        return "\(s / 86_400)d"
    }

    static func usd(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "$%.2f", v)
    }
}
