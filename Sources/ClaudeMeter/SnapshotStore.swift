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

    /// Thresholds and the state-source choice live in settings; the store reads
    /// them so every surface derives the same state from the same rules.
    private let settings: SettingsStore

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
    private var settingsObserver: AnyCancellable?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(settings: SettingsStore = .shared) {
        self.settings = settings
        try? FileManager.default.createDirectory(
            at: Self.sessionsDirectory, withIntermediateDirectories: true)
        reload()
        startWatching()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick = Date() }
        }
        // Editing a threshold changes the derived state without any file
        // changing, so republish when settings do.
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
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

    var liveSessions: [Snapshot] {
        sessions.filter { $0.age < settings.thresholds.asleepAfter }
    }

    var fiveHour: Double? { accountLimits?.limits.fiveHour?.usedPercentage }
    var sevenDay: Double? { accountLimits?.limits.sevenDay?.usedPercentage }
    var fiveHourResetsAt: Double? { accountLimits?.limits.fiveHour?.resetsAt }
    var sevenDayResetsAt: Double? { accountLimits?.limits.sevenDay?.resetsAt }

    /// The fullest live session -- the one that will need /compact first.
    var worstContext: Double? {
        liveSessions.compactMap { $0.context.usedPercentage }.max()
    }

    /// Seconds since the freshest snapshot, or nil when there are none.
    var newestAge: TimeInterval? { sessions.map(\.age).min() }

    /// The reading that escalates the avatar, per the user's state source.
    var drivingPercentage: Double? {
        switch settings.stateSource {
        case .fiveHour: return fiveHour
        case .context:  return worstContext
        case .worst:    return [fiveHour, sevenDay, worstContext].compactMap { $0 }.max()
        }
    }

    /// Kept for the older name used by callers that just want the worst number.
    var worstPercentage: Double? { drivingPercentage }

    /// The single state every surface renders from.
    ///
    /// Order matters: empty before asleep before stale before escalation, so a
    /// number is only ever shown when it is both present and current.
    var state: MeterState {
        if sessions.isEmpty { return .empty }
        if liveSessions.isEmpty { return .asleep }
        if let age = newestAge, age >= Snapshot.Liveness.stale { return .stale }
        guard let pct = drivingPercentage else { return .noData }
        return settings.thresholds.state(for: pct)
    }

    /// Packaged for the avatar styles.
    var avatarInput: AvatarInput {
        AvatarInput(
            state: state,
            percentage: drivingPercentage,
            fiveHour: fiveHour,
            fiveHourResetsAt: fiveHourResetsAt,
            sevenDay: sevenDay,
            context: worstContext,
            sessions: liveSessions.map { $0.context.usedPercentage },
            age: newestAge,
            motionAllowed: settings.motionAllowed,
            showsBackground: settings.showBackground
        )
    }

    /// The value the menubar title shows, per the user's metric choice.
    var menubarValue: Double? {
        switch settings.menubarMetric {
        case .worst:    return [fiveHour, sevenDay, worstContext].compactMap { $0 }.max()
        case .fiveHour: return fiveHour
        case .sevenDay: return sevenDay
        case .context:  return worstContext
        }
    }

    var menubarResetsAt: Double? {
        switch settings.menubarMetric {
        case .sevenDay: return sevenDayResetsAt
        case .context:  return nil     // context has no reset
        default:        return fiveHourResetsAt
        }
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
