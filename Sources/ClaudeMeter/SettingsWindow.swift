import SwiftUI
import AppKit
import ServiceManagement

/// Which pane is showing, and what the preview is being forced to.
/// Not `@State` — see AvatarUIState for why.
@MainActor
final class SettingsUIState: ObservableObject {
    @Published var pane: Pane = .avatar
    /// The sweep slider drags the preview through the whole escalation, so a
    /// style can be judged at every level without waiting to hit them for real.
    @Published var sweep: Double = 62
    @Published var forced: Forced = .none
    @Published var confirmingReset = false

    enum Pane: String, CaseIterable, Identifiable {
        case avatar, source, thresholds, menubar, behaviour
        var id: String { rawValue }
        var label: String {
            switch self {
            case .avatar:     return "Avatar"
            case .source:     return "State source"
            case .thresholds: return "Thresholds"
            case .menubar:    return "Menubar"
            case .behaviour:  return "Behaviour"
            }
        }
        var symbol: String {
            switch self {
            case .avatar:     return "face.smiling"
            case .source:     return "target"
            case .thresholds: return "slider.horizontal.3"
            case .menubar:    return "menubar.rectangle"
            case .behaviour:  return "gearshape"
            }
        }
    }

    /// The states you cannot reach on demand from live data.
    enum Forced: String, CaseIterable, Identifiable {
        case none, asleep, stale, noData, empty, many
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none:   return "Live"
            case .asleep: return "Asleep"
            case .stale:  return "Stale"
            case .noData: return "No data"
            case .empty:  return "Empty"
            case .many:   return "Many"
            }
        }
    }
}

// MARK: - Window

/// Owns the settings window. A real window rather than a popover: it is
/// resizable and stays open while the user experiments with a style.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let ui = SettingsUIState()
    private let settings: SettingsStore

    init(settings: SettingsStore = .shared) {
        self.settings = settings
    }

    /// Debug affordance for screenshots: open straight to a named pane.
    func select(pane name: String) {
        if let p = SettingsUIState.Pane(rawValue: name) { ui.pane = p }
    }

    func show() {
        if window == nil {
            // Tall enough that the Avatar pane — preview strip, style grid and
            // five rows — fits without scrolling, since it is the pane people
            // actually open. The minimum is the spec's 640×520.
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 720),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "claude-meter Settings"
            w.contentMinSize = NSSize(width: 640, height: 520)
            // NSWindow releases itself on close by default, which would leave
            // this reference dangling and crash the second time Settings is
            // opened.
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("claude-meter-settings")
            w.contentView = NSHostingView(
                rootView: SettingsView(settings: settings, ui: ui))
            window = w
        }
        recoverIfOffscreen()
        // The app is an .accessory agent, so it is not in the activation order.
        // Without this the window opens behind whatever is in front.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// `setFrameAutosaveName` restores the last frame verbatim, including onto
    /// a display that has since been unplugged — the saved frame records the
    /// screen it belonged to, and AppKit does not check that it still exists.
    /// Settings then opens somewhere unreachable and looks like it did nothing.
    private func recoverIfOffscreen() {
        guard let w = window else { return }
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(w.frame) }
        guard !onScreen else { return }
        w.setContentSize(NSSize(width: 720, height: 720))
        w.center()
    }
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var ui: SettingsUIState

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                // Pinned to every pane, not just Avatar: thresholds and the
                // state source change what the avatar shows, and a preview you
                // have to navigate back to is a preview nobody uses.
                PreviewStrip(settings: settings, ui: ui)
                ScrollView { pane.frame(maxWidth: .infinity, alignment: .leading) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsUIState.Pane.allCases) { p in
                Button { ui.pane = p } label: {
                    Label(p.label, systemImage: p.symbol)
                        .font(Typo.ui(13, ui.pane == p ? .semibold : .regular))
                        .foregroundColor(ui.pane == p ? .white : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(ui.pane == p ? Color.accentColor : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(8)
        .frame(width: 172)
    }

    @ViewBuilder
    private var pane: some View {
        switch ui.pane {
        case .avatar:     AvatarPane(settings: settings)
        case .source:     StateSourcePane(settings: settings)
        case .thresholds: ThresholdsPane(settings: settings)
        case .menubar:    MenubarPane(settings: settings)
        case .behaviour:  BehaviourPane(settings: settings, ui: ui)
        }
    }
}

// MARK: - Preview strip

struct PreviewStrip: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var ui: SettingsUIState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                half(.light)
                half(.dark)
            }
            .frame(height: 104)

            VStack(spacing: 7) {
                // The track is coloured to the *edited* boundaries, so moving a
                // threshold is visible here immediately.
                ZStack(alignment: .leading) {
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            seg(Tokens.calmC, settings.thresholds.focused, geo.size.width)
                            seg(Tokens.focusedC,
                                settings.thresholds.strained - settings.thresholds.focused,
                                geo.size.width)
                            seg(Tokens.strainedC,
                                settings.thresholds.critical - settings.thresholds.strained,
                                geo.size.width)
                            seg(Tokens.criticalC,
                                100 - settings.thresholds.critical, geo.size.width)
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 6)
                }
                Slider(value: $ui.sweep, in: 0...100)
                    .controlSize(.small)
                    .disabled(ui.forced != .none)
                HStack {
                    ForEach(SettingsUIState.Forced.allCases) { f in
                        Button(f.label) { ui.forced = f }
                            .buttonStyle(.plain)
                            .font(Typo.ui(11, ui.forced == f ? .semibold : .regular))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(
                                Capsule().strokeBorder(
                                    ui.forced == f ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: 1))
                    }
                    Spacer()
                    Text(ui.forced == .none ? "\(Int(ui.sweep))%" : ui.forced.label)
                        .font(Typo.mono(11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
    }

    private func seg(_ color: Color, _ span: Double, _ total: CGFloat) -> some View {
        Rectangle().fill(color).frame(width: max(0, total * span / 100))
    }

    /// Both appearances side by side — an avatar that only works in one is a
    /// bug you would otherwise find weeks later.
    private func half(_ scheme: ColorScheme) -> some View {
        ZStack {
            LinearGradient(
                colors: scheme == .light
                    ? [Color(nsColor: NSColor(hex: 0xE2E7EE)), Color(nsColor: NSColor(hex: 0xC9D2DC))]
                    : [Color(nsColor: NSColor(hex: 0x3D434C)), Color(nsColor: NSColor(hex: 0x22262C))],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            ScaledAvatar(style: settings.styleID,
                         input: Self.input(settings: settings, ui: ui),
                         scale: settings.scale,
                         opacity: settings.opacity)
        }
        .environment(\.colorScheme, scheme)
        .frame(maxWidth: .infinity)
    }

    /// A synthetic snapshot for the preview. Real data cannot be asked to be
    /// critical on demand.
    static func input(settings: SettingsStore, ui: SettingsUIState) -> AvatarInput {
        let pct = ui.sweep
        let now = Date().timeIntervalSince1970
        var i = AvatarInput(
            state: settings.thresholds.state(for: pct),
            percentage: pct,
            fiveHour: pct,
            fiveHourResetsAt: now + 11_220,
            sevenDay: max(0, pct * 0.6),
            context: max(0, pct * 0.8),
            sessions: [pct],
            age: 12,
            motionAllowed: settings.motionAllowed)

        switch ui.forced {
        case .none:   break
        case .asleep: i.state = .asleep; i.age = 2_400
        case .stale:  i.state = .stale;  i.age = 5_400
        case .noData: i.state = .noData; i.fiveHour = nil; i.sevenDay = nil; i.percentage = nil
        case .empty:  i.state = .empty;  i.sessions = []; i.fiveHour = nil; i.percentage = nil
        case .many:   i.sessions = [pct, max(0, pct - 25), max(0, pct - 48)]
        }
        return i
    }
}

// MARK: - Panes

struct AvatarPane: View {
    @ObservedObject var settings: SettingsStore

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Style")
            // Fixed three columns that scroll: entry twelve costs a scroll,
            // not a redesign.
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(AvatarStyleID.allCases) { style in
                    Button { settings.styleID = style } label: {
                        VStack(spacing: 5) {
                            ScaledAvatar(style: style, input: thumbInput, scale: 0.62)
                                .frame(height: 48)
                            Text(style.displayName)
                                .font(Typo.ui(11, .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                            settings.styleID == style ? Color.accentColor : Color.primary.opacity(0.1),
                            lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .help(style.blurb)
                }
            }

            SettingsCard {
                SettingRow("Scale") {
                    HStack {
                        Slider(value: $settings.scale, in: 0.5...4.0).frame(width: 130)
                        Text("\(Int(settings.scale * 100))%")
                            .font(Typo.mono(11)).foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Divider()
                SettingRow("Opacity") {
                    HStack {
                        Slider(value: $settings.opacity, in: 0.3...1.0).frame(width: 130)
                        Text("\(Int(settings.opacity * 100))%")
                            .font(Typo.mono(11)).foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Divider()
                SettingRow("Background plate",
                           note: "Off shows the character alone, with a shadow.") {
                    Toggle("", isOn: $settings.showBackground).labelsHidden()
                }
                Divider()
                SettingRow("Show floating avatar") {
                    Toggle("", isOn: $settings.avatarVisible).labelsHidden()
                }
                Divider()
                SettingRow("Ignore mouse clicks",
                           note: "Clicks pass through to whatever is underneath.") {
                    Toggle("", isOn: $settings.ignoreMouse).labelsHidden()
                }
                Divider()
                SettingRow("Float over full-screen apps") {
                    Toggle("", isOn: $settings.floatOverFullScreen).labelsHidden()
                }
            }
        }
    }

    /// Thumbnails all show the same mid-escalation state so styles are
    /// compared on their design, not on whatever they happen to be showing.
    private var thumbInput: AvatarInput {
        AvatarInput(state: .focused, percentage: 62, fiveHour: 62,
                    fiveHourResetsAt: Date().timeIntervalSince1970 + 11_220,
                    sevenDay: 38, context: 45, sessions: [45],
                    age: 12, motionAllowed: false, showsBackground: true)
    }
}

struct StateSourcePane: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("What drives the avatar")
            Picker("", selection: $settings.stateSource) {
                ForEach(StateSource.allCases) { s in
                    Text(s.label + (s == .worst ? "  (default)" : "")).tag(s)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("Different people are limited by different things: heavy days hit the 5-hour wall first, long sessions hit context first.")
                .font(Typo.ui(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ThresholdsPane: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Escalation")
            SettingsCard {
                stepper("Focused begins at", .focused, settings.thresholds.focused)
                Divider()
                stepper("Strained begins at", .strained, settings.thresholds.strained)
                Divider()
                stepper("Critical begins at", .critical, settings.thresholds.critical)
                Divider()
                SettingRow("Asleep after idle for") {
                    HStack(spacing: 6) {
                        Text("\(Int(settings.thresholds.asleepAfter / 60)) min")
                            .font(Typo.mono(11)).frame(width: 56, alignment: .trailing)
                        Stepper("", value: Binding(
                            get: { settings.thresholds.asleepAfter / 60 },
                            set: { settings.thresholds.asleepAfter = max(1, min(120, $0)) * 60 }),
                                in: 1...120)
                        .labelsHidden()
                    }
                }
            }
            Text("Boundaries clamp to 0–100 and re-order live: raising Focused past Strained pushes Strained up rather than refusing the edit.")
                .font(Typo.ui(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepper(_ title: String, _ key: Thresholds.Key, _ value: Double) -> some View {
        SettingRow(title) {
            HStack(spacing: 6) {
                Text("\(Int(value)) %")
                    .font(Typo.mono(11)).frame(width: 56, alignment: .trailing)
                Stepper("", value: Binding(
                    get: { value },
                    // Routed through set(_:to:) so the ordering rule lives in
                    // one place rather than in every control that edits it.
                    set: { settings.thresholds.set(key, to: $0) }), in: 0...100)
                .labelsHidden()
            }
        }
    }
}

struct MenubarPane: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Menubar item")
            SettingsCard {
                SettingRow("Metric") {
                    Picker("", selection: $settings.menubarMetric) {
                        ForEach(Metric.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 130)
                }
                Divider()
                SettingRow("Display") {
                    Picker("", selection: $settings.menubarDisplay) {
                        ForEach(MenubarDisplay.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
                Divider()
                SettingRow("Include reset countdown") {
                    Toggle("", isOn: $settings.menubarCountdown).labelsHidden()
                }
            }
            Text("Text drops from the right as data disappears: “5h 62% · 3h07m” → “5h 62%” → “62%” → “—”.")
                .font(Typo.ui(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct BehaviourPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var ui: SettingsUIState

    /// install.sh loads a LaunchAgent that already starts this at login. If it
    /// is present, offering a second mechanism would double-launch the app, so
    /// the toggle reports the truth and stays out of the way.
    private var managedByLaunchAgent: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() +
            "/Library/LaunchAgents/com.momentumminds.claude-meter.plist")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Behaviour")
            SettingsCard {
                SettingRow("Launch at login",
                           note: managedByLaunchAgent
                                ? "Managed by the com.momentumminds.claude-meter LaunchAgent."
                                : nil) {
                    Toggle("", isOn: Binding(
                        get: { managedByLaunchAgent || settings.launchAtLogin },
                        set: { setLaunchAtLogin($0) }))
                    .labelsHidden()
                    .disabled(managedByLaunchAgent)
                }
                Divider()
                SettingRow("Always reduce motion",
                           note: "The system setting still wins when it is on.") {
                    Toggle("", isOn: $settings.alwaysReduceMotion).labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button("Reset to defaults…") { ui.confirmingReset = true }
            }
        }
        .alert("Reset all settings?", isPresented: $ui.confirmingReset) {
            Button("Reset", role: .destructive) { settings.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Style, scale, thresholds and menubar options return to their defaults. The avatar's position is kept.")
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        settings.launchAtLogin = on
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // Registration needs a properly signed bundle; an ad-hoc signature
            // can be refused. Reflect the failure rather than lying in the UI.
            settings.launchAtLogin = !on
        }
    }
}

// MARK: - Small pieces

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Typo.ui(10, .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var control: Control

    init(_ title: String, note: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.note = note
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Typo.ui(13))
                if let note {
                    Text(note).font(Typo.ui(10)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 9)
    }
}
