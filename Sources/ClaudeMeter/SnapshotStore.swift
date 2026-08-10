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
    /// Advances when something the app draws may have moved.
    ///
    /// The clock behind it runs once a second, but the value is only assigned
    /// when a redraw could produce different pixels -- see `advance()`. Every
    /// assignment is a redraw of every SwiftUI surface observing this store,
    /// and for a background agent that lives on the desktop all day, a redraw
    /// that lands on the same picture is pure cost.
    @Published private(set) var tick: Date = Date() { didSet { trackState() } }

    /// The state before the current one, and when it changed. The avatar morphs
    /// between poses, so it needs both; nothing else in the app remembers them,
    /// and a style cannot, being a struct rebuilt on every update. This is the
    /// one place the state is actually derived, so it is the one place that can
    /// notice it moving.
    private var settledState: MeterState?
    private var priorState: MeterState?
    private var stateChangedAt: TimeInterval?

    /// Everything the app renders from, at the precision it renders it.
    ///
    /// Two ticks that produce the same value here cannot produce different
    /// pixels anywhere outside a popover, so the second of them is dropped.
    /// The times are bucketed into whole minutes because that is what `Fmt`
    /// prints: countdowns are "3h07m" and ages outside the popover are only
    /// ever shown for data at least five minutes old, so a second of drift
    /// cannot change a character.
    private struct Presentation: Equatable {
        let state: MeterState
        let fiveHour: Double?
        let sevenDay: Double?
        let context: Double?
        let sessions: Int
        let fiveHourMinutes: Int?
        let sevenDayMinutes: Int?
        let ageMinutes: Int?
    }

    private var published: Presentation?

    /// Surfaces that need the tick at its full one-second resolution. Only the
    /// popover does -- it is the one place that prints an age below a minute
    /// ("42s ago"). A count rather than a flag because the menubar's popover
    /// and the avatar's can be open at the same time.
    private var fineConsumers = 0

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
        // The first reload seeds the state tracker, so the avatar comes up in
        // its state rather than morphing into it from nowhere.
        reload()
        startWatching()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
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

    /// Sessions that are doing something, judged on transcript activity rather
    /// than on when the status line last fired — see `Snapshot.activityAge`.
    /// A session running a long subagent is live even though its numbers are
    /// not; `newestAge` is what decides whether those numbers can be trusted,
    /// and the two are deliberately separate.
    var liveSessions: [Snapshot] {
        sessions.filter { $0.activityAge < settings.thresholds.asleepAfter }
    }

    var fiveHour: Double? { Self.current(accountLimits?.limits.fiveHour) }
    var sevenDay: Double? { Self.current(accountLimits?.limits.sevenDay) }
    var fiveHourResetsAt: Double? { accountLimits?.limits.fiveHour?.resetsAt }
    var sevenDayResetsAt: Double? { accountLimits?.limits.sevenDay?.resetsAt }

    /// Whether the last percentage we saw belongs to a window that has since
    /// rolled over. Surfaces use it to say "reset 2h ago" instead of printing a
    /// countdown to a moment that has already been and gone.
    var fiveHourHasReset: Bool { Self.hasReset(accountLimits?.limits.fiveHour) }
    var sevenDayHasReset: Bool { Self.hasReset(accountLimits?.limits.sevenDay) }

    /// What a rate-limit window reads *now*, rather than when it was last
    /// reported.
    ///
    /// The status line only fires while a session is working, so the newest
    /// snapshot can be hours old — and both windows are rolling, so a snapshot
    /// taken before `resets_at` describes a window that no longer exists. The
    /// app used to keep showing that number in grey indefinitely: close the
    /// laptop at 5h 88%, come back the next morning, and it still said 88% when
    /// the window had emptied overnight. Past `resets_at` the honest reading is
    /// zero, which also means the state that greets you is calm rather than
    /// critical.
    ///
    /// Absent stays absent. A window with no percentage is "no data", and a
    /// window with no `resets_at` cannot be shown to have expired, so both pass
    /// through untouched.
    private static func current(_ w: Snapshot.RateLimits.Window?) -> Double? {
        guard let w, let pct = w.usedPercentage else { return nil }
        return hasReset(w) ? 0 : pct
    }

    private static func hasReset(_ w: Snapshot.RateLimits.Window?) -> Bool {
        guard let w, w.usedPercentage != nil, let resets = w.resetsAt else { return false }
        return resets <= Date().timeIntervalSince1970
    }

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
            showsBackground: settings.showBackground,
            previousState: priorState,
            stateChangedAt: stateChangedAt
        )
    }

    /// Records a state change. Called from every path that can cause one: a new
    /// snapshot, the second-by-second tick that ages data into staleness, and
    /// the settings republish that follows a threshold edit.
    private func trackState() {
        let now = state
        guard now != settledState else { return }
        // The first observation is not a change -- there was no pose to leave.
        if let settled = settledState {
            priorState = settled
            stateChangedAt = Date().timeIntervalSinceReferenceDate
        }
        settledState = now
    }

    // MARK: - The clock

    /// One turn of the one-second clock.
    ///
    /// The timer stays at 1 Hz and is not a candidate for being made coarser.
    /// Three things change with nothing but the passage of time -- a session
    /// ageing past `asleepAfter`, a snapshot going stale at the hour, and a
    /// rate-limit window passing its `resets_at` -- and all three have to be
    /// noticed promptly, because each one changes the state the whole app
    /// draws from. Noticing them is arithmetic over a handful of structs and
    /// costs nothing measurable.
    ///
    /// Republishing afterwards is the part that costs. So the tick is only
    /// assigned when it can change what is on screen: when the reading, the
    /// state or a minute-precision countdown moved, or while a popover is open
    /// and wants seconds. In the state this app spends almost all its life in
    /// -- nobody looking, nothing changing -- that is once a minute instead of
    /// sixty times.
    private func advance() {
        let moved = noteState()
        guard moved || fineConsumers > 0 else { return }
        tick = Date()
    }

    /// Records the state and the reading, and reports whether either moved.
    ///
    /// Runs every second whether or not anything is published, because
    /// `trackState` is what dates a state change, and the avatar's pose morph
    /// starts from that date.
    @discardableResult
    private func noteState() -> Bool {
        trackState()
        let now = Date().timeIntervalSince1970
        // floor, not truncation: a countdown that has just gone negative must
        // not share a bucket with one that has not.
        func minutes(until epoch: Double?) -> Int? {
            epoch.map { Int(floor(($0 - now) / 60)) }
        }
        let current = Presentation(
            state: state,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            context: worstContext,
            sessions: sessions.count,
            fiveHourMinutes: minutes(until: fiveHourResetsAt),
            sevenDayMinutes: minutes(until: sevenDayResetsAt),
            ageMinutes: newestAge.map { Int(floor($0 / 60)) })
        defer { published = current }
        return current != published
    }

    /// Registers a surface that needs the tick every second rather than every
    /// time the picture changes. Balance it with `endFineUpdates()`.
    func beginFineUpdates() {
        fineConsumers += 1
        tick = Date()
    }

    func endFineUpdates() {
        fineConsumers = max(0, fineConsumers - 1)
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
        // Assigning `sessions` has already published, so the reading recorded
        // here is one the observers have seen; leaving it stale would make the
        // next tick republish the same picture a second later.
        noteState()
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
