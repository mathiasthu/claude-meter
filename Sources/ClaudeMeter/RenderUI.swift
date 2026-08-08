import SwiftUI
import AppKit

/// Renders the popover and the settings window offscreen.
///
/// Companion to `RenderGrid`: that one covers the avatar art, this one covers
/// the two surfaces you otherwise have to click to see. Both exist because
/// these layouts depend on data shapes — no sessions, ten sessions, a session
/// with no context reading — that are awkward to produce on demand.
///
/// `ClaudeMeter --render-ui <path.png>`
enum RenderUI {

    @MainActor
    static func run(to path: String) -> Bool {
        // Point the store at a scratch directory before anything touches the
        // real one — SnapshotStore.stateDirectory is a lazy static read from
        // this variable.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-meter-render-\(getpid())")
        setenv("CLAUDE_METER_STATE", dir.path, 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        let settings = SettingsStore(
            defaults: UserDefaults(suiteName: "claude-meter-render-\(getpid())")!)
        settings.resetToDefaults()

        let none = store(sessions: 0, settings: settings)
        let three = store(sessions: 3, settings: settings)
        let ten = store(sessions: 10, settings: settings)

        let renderer = ImageRenderer(content: Sheet(
            settings: settings, none: none, three: three, ten: ten))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Writes n synthetic snapshots and returns a store reading them. Session
    /// two deliberately has a null context reading, because a dashed track is
    /// one of the things worth looking at.
    @MainActor
    private static func store(sessions n: Int, settings: SettingsStore) -> SnapshotStore {
        let dir = SnapshotStore.sessionsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in (try? FileManager.default.contentsOfDirectory(at: dir,
                                                               includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
        let now = Date().timeIntervalSince1970
        let names = ["Phase 3 member area and public site rebuild", "billing-migration",
                     "claude-meter", "docs-refresh", "infra-scripts", "reel-share",
                     "tax-tracker", "whoop-data", "luxvps-panel", "focusbox-sync"]
        let pcts: [Double?] = [91, 86, nil, 44, 38, 30, 24, 20, 15, 9]
        for i in 0..<n {
            let pct = pcts[i % pcts.count]
            let ctx = pct.map { "\($0)" } ?? "null"
            let json = """
            {"ts":\(now - Double(i) * 9),"session_id":"s\(i)","session_name":"\(names[i % names.count])",
             "cwd":"/Users/x/\(names[i % names.count])","model":"\(i % 2 == 0 ? "Opus 5 (1M context)" : "Sonnet 4.8")",
             "effort":"high","fast_mode":false,
             "context":{"used_percentage":\(ctx),"remaining_percentage":null,
               "total_input_tokens":\(180_000 + i * 9000),"total_output_tokens":400,
               "size":\(i % 2 == 0 ? 1_000_000 : 200_000),"current_usage":null},
             "exceeds_200k":false,
             "cost":{"total_cost_usd":\(12.05 - Double(i)),"total_duration_ms":1000,
               "total_api_duration_ms":1,"lines_added":0,"lines_removed":0},
             "rate_limits":{"five_hour":{"used_percentage":78,"resets_at":\(now + 7080)},
               "seven_day":{"used_percentage":52,"resets_at":\(now + 225_000)}}}
            """
            try? json.write(to: dir.appendingPathComponent("s\(i).json"),
                            atomically: true, encoding: .utf8)
        }
        let s = SnapshotStore(settings: settings)
        s.reload()
        return s
    }

    // MARK: - Sheet

    struct Sheet: View {
        let settings: SettingsStore
        @ObservedObject var none: SnapshotStore
        @ObservedObject var three: SnapshotStore
        @ObservedObject var ten: SnapshotStore

        var body: some View {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("claude-meter — popover and settings")
                        .font(.system(size: 22, weight: .bold))
                    Text("Rendered offscreen with synthetic data.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Dropdown — none · three · ten sessions")
                        .font(.system(size: 15, weight: .semibold))
                    HStack(alignment: .top, spacing: 16) {
                        popover(none)
                        popover(three)
                        popover(ten)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Settings — Avatar pane")
                        .font(.system(size: 15, weight: .semibold))
                    settingsWindow(pane: .avatar)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Settings — Thresholds pane")
                        .font(.system(size: 15, weight: .semibold))
                    settingsWindow(pane: .thresholds)
                }
            }
            .padding(28)
            .background(Color(nsColor: NSColor(hex: 0xF5F5F7)))
            .environment(\.colorScheme, .light)
            .fixedSize()
        }

        private func popover(_ store: SnapshotStore) -> some View {
            SessionListView(store: store, settings: settings,
                            onToggleAvatar: {}, onOpenSettings: {}, onQuit: {})
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        }

        private func settingsWindow(pane: SettingsUIState.Pane) -> some View {
            let ui = SettingsUIState()
            ui.pane = pane
            return SettingsView(settings: settings, ui: ui)
                .frame(width: 720, height: 560)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        }
    }
}
