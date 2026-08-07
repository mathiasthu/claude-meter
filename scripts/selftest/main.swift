import Foundation
import AppKit

// Headless harness for SnapshotStore: verifies directory watching, mood
// aggregation, liveness and staleness against files written at runtime.

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("cm-store-test-\(getpid())")
let sessions = tmp.appendingPathComponent("sessions")
try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
setenv("CLAUDE_METER_STATE", tmp.path, 1)

func write(_ id: String, ctx: Double?, five: Double?, agoSeconds: Double = 0) {
    let ts = Date().timeIntervalSince1970 - agoSeconds
    let ctxJSON = ctx.map { "\($0)" } ?? "null"
    let rl = five.map {
        "{\"five_hour\":{\"used_percentage\":\($0),\"resets_at\":\(ts + 3600)},\"seven_day\":{\"used_percentage\":10,\"resets_at\":\(ts + 90000)}}"
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
    let store = SnapshotStore()

    check("empty dir -> asleep", store.mood == .asleep, "\(store.mood)")

    // --- watcher: written without calling reload() ---
    write("alpha", ctx: 30, five: 20)
    var picked = false
    for _ in 0..<40 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if store.sessions.count == 1 { picked = true; break }
    }
    check("directory watch picked up new file", picked, "sessions=\(store.sessions.count)")
    check("mood calm at 30/20", store.mood == .calm, "\(store.mood)")
    check("worst = 30", store.worstPercentage == 30, "\(String(describing: store.worstPercentage))")

    // --- context drives mood above rate limits ---
    write("beta", ctx: 88, five: 20)
    store.reload()
    check("two sessions listed", store.sessions.count == 2, "\(store.sessions.count)")
    check("mood alarmed from ctx 88", store.mood == .alarmed, "\(store.mood)")

    // --- rate limit drives mood above context ---
    write("beta", ctx: 10, five: 20)
    write("gamma", ctx: 5, five: 74)
    store.reload()
    check("mood sweating from 5h 74", store.mood == .sweating, "\(store.mood)")

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
    check("no live sessions -> asleep", store.mood == .asleep, "\(store.mood)")
    check("old snapshot still listed", store.sessions.count == 1, "\(store.sessions.count)")

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
    check("mood still derived from ctx", store.mood == .focused, "\(store.mood)")

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
    check("back to asleep", store.mood == .asleep, "\(store.mood)")

    // --- corrupt file must not take the store down ---
    try? "{ not json".write(to: sessions.appendingPathComponent("broken.json"),
                            atomically: true, encoding: .utf8)
    write("good", ctx: 10, five: 10)
    store.reload()
    check("corrupt file skipped, good file kept", store.sessions.count == 1, "\(store.sessions.count)")

    try? FileManager.default.removeItem(at: tmp)
    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
