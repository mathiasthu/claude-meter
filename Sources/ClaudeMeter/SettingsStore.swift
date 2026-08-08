import SwiftUI
import AppKit
import Combine

/// Every user preference, in one observable object backed by `UserDefaults`.
///
/// Deliberately not `@AppStorage`: that is a macro, and SwiftUI's macro plugin
/// is absent from every toolchain on this machine (see HANDOFF.md). A plain
/// `ObservableObject` with `@Published` properties works everywhere and gives
/// views real bindings via `$store.property`.
///
/// Views must read settings from here rather than touching `UserDefaults`, so
/// "reset to defaults" is one operation instead of a hunt.
@MainActor
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    // MARK: Avatar

    @Published var styleID: AvatarStyleID = .pixelCreature { didSet { save() } }
    @Published var scale: Double = 1.0                      { didSet { save() } }
    @Published var opacity: Double = 0.95                   { didSet { save() } }
    @Published var avatarVisible: Bool = true               { didSet { save() } }
    @Published var ignoreMouse: Bool = false                { didSet { save() } }
    @Published var floatOverFullScreen: Bool = true         { didSet { save() } }

    // MARK: State source

    @Published var stateSource: StateSource = .worst        { didSet { save() } }

    // MARK: Thresholds

    @Published var thresholds: Thresholds = .default        { didSet { save() } }

    // MARK: Menubar

    @Published var menubarMetric: Metric = .fiveHour        { didSet { save() } }
    @Published var menubarDisplay: MenubarDisplay = .both   { didSet { save() } }
    @Published var menubarCountdown: Bool = true            { didSet { save() } }

    // MARK: Behaviour

    @Published var launchAtLogin: Bool = false              { didSet { save() } }
    @Published var alwaysReduceMotion: Bool = false         { didSet { save() } }

    /// True when animation is permitted: the system setting, which the user can
    /// tighten but not loosen — an explicit accessibility preference should not
    /// be overridable by an app's own checkbox.
    var motionAllowed: Bool {
        !alwaysReduceMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Persistence

    private let defaults: UserDefaults
    private var loading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private enum K {
        static let style = "avatar.style"
        static let scale = "avatar.scale"
        static let opacity = "avatar.opacity"
        static let visible = "avatar.visible"
        static let ignoreMouse = "avatar.ignoreMouse"
        static let fullScreen = "avatar.floatOverFullScreen"
        static let source = "state.source"
        static let thresholds = "state.thresholds"
        static let mbMetric = "menubar.metric"
        static let mbDisplay = "menubar.display"
        static let mbCountdown = "menubar.countdown"
        static let launchAtLogin = "behaviour.launchAtLogin"
        static let reduceMotion = "behaviour.alwaysReduceMotion"
    }

    private func load() {
        loading = true
        defer { loading = false }

        if let s = defaults.string(forKey: K.style), let v = AvatarStyleID(rawValue: s) {
            styleID = v
        }
        // `object(forKey:)` rather than `double(forKey:)` — the latter returns 0
        // for an unset key, which would silently collapse the avatar to nothing
        // on first launch.
        if let v = defaults.object(forKey: K.scale) as? Double { scale = v }
        if let v = defaults.object(forKey: K.opacity) as? Double { opacity = v }
        if let v = defaults.object(forKey: K.visible) as? Bool { avatarVisible = v }
        if let v = defaults.object(forKey: K.ignoreMouse) as? Bool { ignoreMouse = v }
        if let v = defaults.object(forKey: K.fullScreen) as? Bool { floatOverFullScreen = v }
        if let s = defaults.string(forKey: K.source), let v = StateSource(rawValue: s) {
            stateSource = v
        }
        if let data = defaults.data(forKey: K.thresholds),
           let v = try? JSONDecoder().decode(Thresholds.self, from: data) {
            thresholds = v
        }
        if let s = defaults.string(forKey: K.mbMetric), let v = Metric(rawValue: s) {
            menubarMetric = v
        }
        if let s = defaults.string(forKey: K.mbDisplay), let v = MenubarDisplay(rawValue: s) {
            menubarDisplay = v
        }
        if let v = defaults.object(forKey: K.mbCountdown) as? Bool { menubarCountdown = v }
        if let v = defaults.object(forKey: K.launchAtLogin) as? Bool { launchAtLogin = v }
        if let v = defaults.object(forKey: K.reduceMotion) as? Bool { alwaysReduceMotion = v }
    }

    private func save() {
        // Every property's didSet calls this, including the ones load() sets.
        // Without the guard, loading would immediately rewrite what it read.
        guard !loading else { return }
        defaults.set(styleID.rawValue, forKey: K.style)
        defaults.set(scale, forKey: K.scale)
        defaults.set(opacity, forKey: K.opacity)
        defaults.set(avatarVisible, forKey: K.visible)
        defaults.set(ignoreMouse, forKey: K.ignoreMouse)
        defaults.set(floatOverFullScreen, forKey: K.fullScreen)
        defaults.set(stateSource.rawValue, forKey: K.source)
        if let data = try? JSONEncoder().encode(thresholds) {
            defaults.set(data, forKey: K.thresholds)
        }
        defaults.set(menubarMetric.rawValue, forKey: K.mbMetric)
        defaults.set(menubarDisplay.rawValue, forKey: K.mbDisplay)
        defaults.set(menubarCountdown, forKey: K.mbCountdown)
        defaults.set(launchAtLogin, forKey: K.launchAtLogin)
        defaults.set(alwaysReduceMotion, forKey: K.reduceMotion)
    }

    func resetToDefaults() {
        loading = true
        styleID = .pixelCreature
        scale = 1.0
        opacity = 0.95
        avatarVisible = true
        ignoreMouse = false
        floatOverFullScreen = true
        stateSource = .worst
        thresholds = .default
        menubarMetric = .fiveHour
        menubarDisplay = .both
        menubarCountdown = true
        alwaysReduceMotion = false
        loading = false
        save()
    }
}

// MARK: - Choices

/// Which reading escalates the avatar. Different people are limited by
/// different things: a heavy user hits the 5-hour wall, someone on long
/// sessions hits context first.
enum StateSource: String, CaseIterable, Identifiable {
    case worst, fiveHour, context
    var id: String { rawValue }
    var label: String {
        switch self {
        case .worst:    return "Worst of all three metrics"
        case .fiveHour: return "5-hour window only"
        case .context:  return "Session context only"
        }
    }
}

enum Metric: String, CaseIterable, Identifiable {
    case worst, fiveHour, sevenDay, context
    var id: String { rawValue }
    var label: String {
        switch self {
        case .worst:    return "Worst"
        case .fiveHour: return "5-hour"
        case .sevenDay: return "7-day"
        case .context:  return "Context"
        }
    }
    /// Short prefix used in the menubar title, e.g. "5h 62%".
    var prefix: String {
        switch self {
        case .worst:    return ""
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        case .context:  return "ctx"
        }
    }
}

enum MenubarDisplay: String, CaseIterable, Identifiable {
    case icon, text, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .icon: return "Icon"
        case .text: return "Text"
        case .both: return "Both"
        }
    }
    var showsIcon: Bool { self != .text }
    var showsText: Bool { self != .icon }
}
