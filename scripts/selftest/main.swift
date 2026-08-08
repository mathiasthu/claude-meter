import Foundation
import AppKit
import SwiftUI

// Headless harness for SnapshotStore: verifies directory watching, state
// aggregation, liveness and staleness against files written at runtime.

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("cm-store-test-\(getpid())")
let sessions = tmp.appendingPathComponent("sessions")
try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
setenv("CLAUDE_METER_STATE", tmp.path, 1)

func write(_ id: String, ctx: Double?, five: Double?, agoSeconds: Double = 0,
           fiveResetsIn: Double = 3600) {
    let ts = Date().timeIntervalSince1970 - agoSeconds
    let ctxJSON = ctx.map { "\($0)" } ?? "null"
    let rl = five.map {
        "{\"five_hour\":{\"used_percentage\":\($0),\"resets_at\":\(ts + fiveResetsIn)},\"seven_day\":{\"used_percentage\":10,\"resets_at\":\(ts + 90000)}}"
    } ?? "null"
    let json = """
    {"ts":\(ts),"session_id":"\(id)","session_name":"\(id)","cwd":"/tmp/\(id)","model":"Opus","effort":"high","fast_mode":false,
     "context":{"used_percentage":\(ctxJSON),"remaining_percentage":null,"total_input_tokens":1000,"total_output_tokens":10,"size":200000,"current_usage":null},
     "exceeds_200k":false,"cost":{"total_cost_usd":1.0,"total_duration_ms":1000,"total_api_duration_ms":1,"lines_added":0,"lines_removed":0},
     "rate_limits":\(rl)}
    """
    // Mirror the collector's `mv -f`: atomic AND replacing. Plain
    // moveItem() throws when the destination exists, which silently turns a
    // rewrite into a no-op.
    let tmpFile = sessions.appendingPathComponent(".\(id).tmp")
    let dest = sessions.appendingPathComponent("\(id).json")
    try? json.write(to: tmpFile, atomically: false, encoding: .utf8)
    if FileManager.default.fileExists(atPath: dest.path) {
        _ = try? FileManager.default.replaceItemAt(dest, withItemAt: tmpFile)
    } else {
        try? FileManager.default.moveItem(at: tmpFile, to: dest)
    }
}

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    print("\(cond ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
    if !cond { failures += 1 }
}

MainActor.assumeIsolated {
    let settings = SettingsStore(defaults: UserDefaults(suiteName: "claude-meter-selftest-\(getpid())")!)
    settings.resetToDefaults()
    let store = SnapshotStore(settings: settings)

    // No sessions at all is `empty`, not `asleep` — asleep means sessions
    // exist but none of them are live.
    check("empty dir -> empty", store.state == .empty, "\(store.state)")

    // --- watcher: written without calling reload() ---
    write("alpha", ctx: 30, five: 20)
    var picked = false
    for _ in 0..<40 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if store.sessions.count == 1 { picked = true; break }
    }
    check("directory watch picked up new file", picked, "sessions=\(store.sessions.count)")
    check("state calm at 30/20", store.state == .calm, "\(store.state)")
    check("worst = 30", store.worstPercentage == 30, "\(String(describing: store.worstPercentage))")

    // --- context drives state above rate limits ---
    write("beta", ctx: 88, five: 20)
    store.reload()
    check("two sessions listed", store.sessions.count == 2, "\(store.sessions.count)")
    check("state critical from ctx 88", store.state == .critical, "\(store.state)")

    // --- rate limit drives state above context ---
    write("beta", ctx: 10, five: 20)
    write("gamma", ctx: 5, five: 74)
    store.reload()
    check("state strained from 5h 74", store.state == .strained, "\(store.state)")

    // --- account limits come from the freshest snapshot ---
    check("accountLimits 5h == 74",
          store.accountLimits?.limits.fiveHour?.usedPercentage == 74,
          "\(String(describing: store.accountLimits?.limits.fiveHour?.usedPercentage))")

    // --- liveness / staleness ---
    for f in (try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? [] {
        try? FileManager.default.removeItem(at: f)
    }
    write("old", ctx: 40, five: 40, agoSeconds: 400)   // > 5 min
    store.reload()
    check("old snapshot not live", store.liveSessions.isEmpty, "live=\(store.liveSessions.count)")
    check("no live sessions -> asleep", store.state == .asleep, "\(store.state)")
    check("old snapshot still listed", store.sessions.count == 1, "\(store.sessions.count)")

    // --- a window past its reset reads zero, not its last value ---
    //
    // The status line stops firing when you stop working, so the newest
    // snapshot can predate the rollover by hours. Reporting the number it
    // carries would greet you with the previous window's ceiling.
    for f in (try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? [] {
        try? FileManager.default.removeItem(at: f)
    }
    write("live", ctx: 10, five: 88, fiveResetsIn: 1800)
    store.reload()
    check("window still open keeps its value", store.fiveHour == 88,
          "\(String(describing: store.fiveHour))")
    check("window still open is not reset", store.fiveHourHasReset == false)
    check("state critical from 5h 88", store.state == .critical, "\(store.state)")

    write("live", ctx: 10, five: 88, fiveResetsIn: -60)
    store.reload()
    check("elapsed window reads 0", store.fiveHour == 0,
          "\(String(describing: store.fiveHour))")
    check("elapsed window reports hasReset", store.fiveHourHasReset)
    check("elapsed window calms the state", store.state == .calm, "\(store.state)")
    check("elapsed window keeps its resets_at for the age line",
          store.fiveHourResetsAt != nil)
    check("the 7-day window is untouched by the 5-hour rollover",
          store.sevenDay == 10 && store.sevenDayHasReset == false,
          "\(String(describing: store.sevenDay))")

    // Absence is not zero, and never becomes zero by expiring.
    write("nolimits", ctx: 10, five: nil)
    for f in (try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent == "live.json" {
        try? FileManager.default.removeItem(at: f)
    }
    store.reload()
    check("no rate limits stays nil, not 0", store.fiveHour == nil,
          "\(String(describing: store.fiveHour))")
    check("no rate limits is not a reset", store.fiveHourHasReset == false)

    for f in (try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? [] {
        try? FileManager.default.removeItem(at: f)
    }
    write("old", ctx: 40, five: 40, agoSeconds: 400)
    store.reload()

    write("veryold", ctx: 40, five: 40, agoSeconds: 7200) // > 60 min
    store.reload()
    check("very old is stale", store.sessions.first(where: { $0.sessionId == "veryold" })?.isStale == true)

    // --- missing rate_limits (non-subscriber / pre-first-response) ---
    for f in (try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? [] {
        try? FileManager.default.removeItem(at: f)
    }
    write("nolimits", ctx: 55, five: nil)
    store.reload()
    check("decodes with rate_limits null", store.sessions.count == 1, "\(store.sessions.count)")
    check("accountLimits nil", store.accountLimits == nil)
    check("state still derived from ctx", store.state == .focused, "\(store.state)")

    // --- null context percentage (post-/compact) ---
    write("nullctx", ctx: nil, five: nil)
    store.reload()
    check("null used_percentage decodes",
          store.sessions.contains { $0.sessionId == "nullctx" && $0.context.usedPercentage == nil })

    // --- deletion (the SessionEnd hook path) ---
    for f in (try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? [] {
        try? FileManager.default.removeItem(at: f)
    }
    var cleared = false
    for _ in 0..<40 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if store.sessions.isEmpty { cleared = true; break }
    }
    check("deletion observed by watcher", cleared, "sessions=\(store.sessions.count)")
    check("all deleted -> empty", store.state == .empty, "\(store.state)")

    // --- corrupt file must not take the store down ---
    try? "{ not json".write(to: sessions.appendingPathComponent("broken.json"),
                            atomically: true, encoding: .utf8)
    write("good", ctx: 10, five: 10)
    store.reload()
    check("corrupt file skipped, good file kept", store.sessions.count == 1, "\(store.sessions.count)")


    // --- settings: defaults on a clean domain ---
    let suite = "claude-meter-selftest-settings-\(getpid())"
    let d1 = UserDefaults(suiteName: suite)!
    d1.removePersistentDomain(forName: suite)
    let s1 = SettingsStore(defaults: d1)
    check("default style is pixel creature", s1.styleID == .pixelCreature, "\(s1.styleID)")
    check("default thresholds 50/70/85",
          s1.thresholds == Thresholds.default, "\(s1.thresholds)")
    check("default scale is 1.75", s1.scale == 1.75, "\(s1.scale)")
    check("background plate off by default", s1.showBackground == false, "\(s1.showBackground)")

    // --- settings: persistence round-trip ---
    s1.styleID = .pill
    s1.scale = 1.4
    s1.menubarMetric = .sevenDay
    s1.thresholds.set(.critical, to: 90)
    let s2 = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    check("style persists", s2.styleID == .pill, "\(s2.styleID)")
    check("scale persists", s2.scale == 1.4, "\(s2.scale)")
    check("menubar metric persists", s2.menubarMetric == .sevenDay, "\(s2.menubarMetric)")
    check("thresholds persist", s2.thresholds.critical == 90, "\(s2.thresholds.critical)")

    // --- settings: thresholds stay ordered ---
    var t = Thresholds.default
    t.set(.focused, to: 95)
    check("raising focused pushes strained up", t.strained >= 95, "\(t)")
    check("raising focused pushes critical up", t.critical >= t.strained, "\(t)")
    t = Thresholds.default
    t.set(.critical, to: 20)
    check("lowering critical pulls strained down", t.strained <= 20, "\(t)")
    check("lowering critical pulls focused down", t.focused <= t.strained, "\(t)")
    t = Thresholds.default
    t.set(.focused, to: -30)
    check("thresholds clamp at 0", t.focused == 0, "\(t.focused)")
    t.set(.critical, to: 300)
    check("thresholds clamp at 100", t.critical == 100, "\(t.critical)")

    // --- settings: reset restores defaults ---
    s1.resetToDefaults()
    check("reset restores style", s1.styleID == .pixelCreature, "\(s1.styleID)")
    check("reset restores thresholds", s1.thresholds == Thresholds.default, "\(s1.thresholds)")
    d1.removePersistentDomain(forName: suite)

    // --- every style renders every state without trapping ---
    var rendered = 0
    for style in AvatarStyleID.allCases {
        for st in MeterState.allCases {
            let input = AvatarInput(state: st, percentage: 62, fiveHour: 62,
                                    fiveHourResetsAt: Date().timeIntervalSince1970 + 3600,
                                    sevenDay: 38, context: 45,
                                    sessions: [45, 20, 80], age: 30, motionAllowed: false)
            _ = ImageRenderer(content: ScaledAvatar(style: style, input: input)).nsImage
            rendered += 1
        }
    }
    check("all styles render all states",
          rendered == AvatarStyleID.allCases.count * MeterState.allCases.count,
          "\(rendered) combinations")

    try? FileManager.default.removeItem(at: tmp)
    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
