import Foundation
import Combine

/// Reads every published snapshot and republishes them as they change.
///
/// Two update sources, both needed:
///   - A directory watch, so a new status line refresh shows up immediately.
///   - A one-second timer, because reset countdowns tick and a session goes
///     stale purely with the passage of time -- no file changes for either.
@MainActor
final class SnapshotStore: ObservableObject {

    @Published private(set) var sessions: [Snapshot] = []
    /// Advances once a second so SwiftUI recomputes countdowns and staleness.
    @Published private(set) var tick: Date = Date()

    static let stateDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_METER_STATE"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/state/claude-meter")
    }()

    static var sessionsDirectory: URL {
        stateDirectory.appendingPathComponent("sessions")
    }

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: CInt = -1
    private var timer: Timer?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init() {
        try? FileManager.default.createDirectory(
            at: Self.sessionsDirectory, withIntermediateDirectories: true)
        reload()
        startWatching()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick = Date() }
        }
    }

    deinit {
        watcher?.cancel()
        timer?.invalidate()
    }

    // MARK: - Aggregates

    /// Rate limits are account-wide, so any session's copy is as good as any
    /// other -- take the freshest one. Sessions that have not yet seen an API
    /// response carry no rate_limits at all, which is why this scans rather
    /// than just reading sessions.first.
    var accountLimits: (limits: Snapshot.RateLimits, asOf: Double)? {
        for s in sessions.sorted(by: { $0.ts > $1.ts }) {
            if let rl = s.rateLimits, rl.fiveHour != nil || rl.sevenDay != nil {
                return (rl, s.ts)
            }
        }
        return nil
    }

    var liveSessions: [Snapshot] { sessions.filter(\.isLive) }

    /// Drives the avatar's expression. Any one of the three filling up is
    /// worth reacting to: the 5h and 7d windows throttle the account, and a
    /// full context window stops the session you are actually working in.
    var worstPercentage: Double? {
        var candidates: [Double] = []
        if let rl = accountLimits?.limits {
            if let v = rl.fiveHour?.usedPercentage { candidates.append(v) }
            if let v = rl.sevenDay?.usedPercentage { candidates.append(v) }
        }
        candidates.append(contentsOf: liveSessions.compactMap { $0.context.usedPercentage })
        return candidates.max()
    }

    var mood: Mood {
        guard !liveSessions.isEmpty else { return .asleep }
        // Live sessions but no usable numbers yet (fresh session, or a
        // non-subscriber who never receives rate_limits at all).
        guard let worst = worstPercentage else { return .stale }
        if sessions.allSatisfy(\.isStale) { return .stale }
        return Mood(percentage: worst)
    }

    // MARK: - Loading

    func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: Self.sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        var loaded: [Snapshot] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let snap = try? decoder.decode(Snapshot.self, from: data)
            else { continue }  // a torn or half-written file; the next write fixes it
            loaded.append(snap)
        }
        // Most recently active first -- that is the session you are looking at.
        sessions = loaded.sorted { $0.ts > $1.ts }
    }

    // MARK: - Watching

    private func startWatching() {
        let fd = open(Self.sessionsDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.watchedFD >= 0 { close(self.watchedFD); self.watchedFD = -1 }
        }
        source.resume()
        watcher = source
    }
}
