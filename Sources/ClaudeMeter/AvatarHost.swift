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
    /// Drag bookkeeping, so a click can be told apart from a drag.
    ///
    /// Tracked in screen coordinates via `NSEvent.mouseLocation` rather than
    /// the gesture's own translation: the window moves under the cursor while
    /// dragging, which makes view-relative translation fight itself.
    ///
    /// `pressMouse` is where the press started, not where the pointer was last
    /// seen. The panel positions itself from an absolute mouse reading every
    /// event, so nothing here may accumulate — see `AvatarPanel.dragTo`.
    var pressMouse: NSPoint?
    var lastMouse: NSPoint?
    var dragDistance: CGFloat = 0

    /// When the last click landed, for the styles that react to being poked.
    /// Published because the reaction has to reach the sprite: nothing else in
    /// this class changes what is on screen, so it is the only field that
    /// needs to push an update.
    @Published var clickedAt: TimeInterval?

    /// Below this a press counts as a click, not a drag. Small enough that a
    /// deliberate nudge still moves the avatar, large enough to survive the
    /// wobble in a normal click.
    static let clickSlop: CGFloat = 3
}

/// What the floating panel actually hosts: whichever style the user picked,
/// fed from the store.
///
/// It has no chrome of its own — every style carries its own ground, because
/// each one needs a different shape of it, and there is deliberately no close
/// button. The avatar is a character sitting on the desktop; a control that
/// appears on approach makes it a widget, and the hit target it needs is a
/// quarter of the whole sprite at 1×. Hiding it lives in the menubar menu and
/// in the popover, both of which are reachable without covering the art.
struct AvatarHost: View {
    @ObservedObject var store: SnapshotStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var ui: AvatarUIState
    /// Called on a press that did not turn into a drag.
    var onClick: () -> Void = {}
    /// Called once when a press begins, with the pointer in screen coordinates,
    /// so the panel can record where it was grabbed.
    var onGrab: (NSPoint) -> Void = { _ in }
    /// Called with the absolute pointer position on every event past the slop.
    var onDrag: (NSPoint) -> Void = { _ in }

    var body: some View {
        ScaledAvatar(style: settings.styleID,
                     input: input,
                     scale: settings.scale,
                     opacity: settings.opacity)
            // minimumDistance 0 so the press is tracked from the first event;
            // whether it was a click or a drag is decided on release.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        let now = NSEvent.mouseLocation
                        if let last = ui.lastMouse {
                            ui.dragDistance += hypot(now.x - last.x, now.y - last.y)
                            // Only actually move once past the slop, so a click
                            // never nudges the avatar a pixel sideways.
                            if ui.dragDistance >= AvatarUIState.clickSlop {
                                onDrag(now)
                            }
                        } else {
                            ui.dragDistance = 0
                            ui.pressMouse = now
                            onGrab(now)
                        }
                        ui.lastMouse = now
                    }
                    .onEnded { _ in
                        let wasClick = ui.dragDistance < AvatarUIState.clickSlop
                        ui.lastMouse = nil
                        ui.pressMouse = nil
                        ui.dragDistance = 0
                        if wasClick {
                            // Recorded before the popover opens, so the sprite
                            // starts reacting on the same frame the panel does.
                            ui.clickedAt = Date().timeIntervalSinceReferenceDate
                            onClick()
                        }
                    }
            )
            .help(tooltip)
    }

    /// The store's reading plus the one thing the store cannot know: that the
    /// user just clicked this window.
    private var input: AvatarInput {
        var input = store.avatarInput
        input.clickedAt = ui.clickedAt
        return input
    }

    /// The numbers the compact styles cannot show, one hover away. Clicking
    /// opens the full panel; this is the glance version.
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
        lines.append("Click for details · drag to move")
        return lines.joined(separator: "\n")
    }
}
