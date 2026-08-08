import SwiftUI
import AppKit

/// View-local state for the floating card.
///
/// This exists instead of `@State` because SwiftUI's macro plugin
/// (`SwiftUIMacros`) is not present in either toolchain on this machine, and
/// `@State` is a macro in the current SDK -- it fails to compile with
/// "plugin for module 'SwiftUIMacros' not found". `@ObservedObject` is a plain
/// property wrapper, so it still works. Owned by AvatarPanel, which outlives
/// every re-render of the view.
@MainActor
final class AvatarUIState: ObservableObject {
    @Published var hovering = false
}

/// What the floating panel actually hosts: whichever style the user picked,
/// fed from the store, with a hover-revealed close affordance.
///
/// The card itself has no chrome — every style carries its own ground, because
/// each one needs a different shape of it.
struct AvatarHost: View {
    @ObservedObject var store: SnapshotStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var ui: AvatarUIState
    var onClose: () -> Void = {}

    var body: some View {
        ScaledAvatar(style: settings.styleID,
                     input: store.avatarInput,
                     scale: settings.scale,
                     opacity: settings.opacity)
            .overlay(alignment: .topTrailing) {
                if ui.hovering && !settings.ignoreMouse {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                    .help("Hide the avatar (reopen from the menubar)")
                }
            }
            .onHover { ui.hovering = $0 }
            .help(tooltip)
    }

    /// The numbers the compact styles cannot show, one hover away.
    private var tooltip: String {
        var lines: [String] = [store.state.headline]
        if let five = store.fiveHour {
            var l = "5-hour \(Fmt.percent(five))"
            if let r = Fmt.countdown(to: store.fiveHourResetsAt, spaced: true) {
                l += " · resets \(r)"
            }
            lines.append(l)
        }
        if let seven = store.sevenDay { lines.append("7-day \(Fmt.percent(seven))") }
        if let ctx = store.worstContext { lines.append("Context \(Fmt.percent(ctx))") }
        let live = store.liveSessions.count
        lines.append(live == 1 ? "1 live session" : "\(live) live sessions")
        if let age = store.newestAge, age >= Snapshot.Liveness.live {
            lines.append("Last update \(Fmt.age(age)) ago")
        }
        return lines.joined(separator: "\n")
    }
}
