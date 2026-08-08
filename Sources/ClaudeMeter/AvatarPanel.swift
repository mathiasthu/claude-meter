import AppKit
import SwiftUI
import Combine

/// The floating avatar window.
///
/// An NSPanel rather than an NSWindow so it can be `.nonactivatingPanel`:
/// clicking or dragging it must never pull focus away from whatever you are
/// typing in. It floats above normal windows, follows you across Spaces, and
/// remembers where you put it.
@MainActor
final class AvatarPanel: NSPanel {

    private static let originKey = "avatar.origin"

    private var moveObserver: AnyObject?
    private var settingsObserver: AnyCancellable?
    /// Held here so the drag bookkeeping survives re-renders -- see
    /// AvatarUIState for why this is not `@State`.
    private let ui = AvatarUIState()
    private let settings: SettingsStore
    private var host: NSHostingView<AvatarHost>!

    init(store: SnapshotStore, settings: SettingsStore = .shared,
         onClick: @escaping () -> Void = {}) {
        self.settings = settings
        super.init(
            contentRect: NSRect(origin: .zero, size: settings.styleID.naturalSize),
            // .borderless drops the title bar; .nonactivatingPanel is what
            // keeps clicks from stealing focus.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        // Each style draws its own ground, so the window must not add a second
        // one behind it.
        hasShadow = false
        // Dragging is handled by the hosting view, which has to tell a drag
        // apart from a click. isMovableByWindowBackground would swallow the
        // press before that decision could be made.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false

        host = NSHostingView(rootView: AvatarHost(
            store: store, settings: settings, ui: ui,
            onClick: onClick,
            onDrag: { [weak self] dx, dy in self?.moveBy(dx: dx, dy: dy) }))
        contentView = host

        applySettings()
        resizeToFit()
        restorePosition()

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        }

        // Style, scale and the collection-behaviour toggles all change the
        // window itself, not just its contents.
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.applySettings()
                self?.resizeToFit()
            }
        }
    }

    deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
    }

    /// Moves the panel by a screen-space delta, and remembers where it landed.
    /// Not clamped mid-drag — the user is allowed to park it half off an edge
    /// if they want; only automatic resizes get pulled back.
    private func moveBy(dx: CGFloat, dy: CGFloat) {
        setFrameOrigin(NSPoint(x: frame.origin.x + dx, y: frame.origin.y + dy))
    }

    /// Never becomes key: typing always goes to the app underneath.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Settings

    private func applySettings() {
        ignoresMouseEvents = settings.ignoreMouse
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary]
        if settings.floatOverFullScreen { behavior.insert(.fullScreenAuxiliary) }
        collectionBehavior = behavior
    }

    /// The pill grows with its text and the creatures do not, so the window is
    /// sized from what the view actually wants rather than from a constant.
    private func resizeToFit() {
        let fitted = host.fittingSize
        guard fitted.width > 1, fitted.height > 1 else { return }
        guard abs(fitted.width - frame.width) > 0.5
                || abs(fitted.height - frame.height) > 0.5 else { return }
        // Keep the top-left corner planted: growing downward from where the
        // user parked it is less surprising than growing from the origin.
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - fitted.height,
                        width: fitted.width, height: fitted.height),
                 display: true)
        clampOnScreen()
    }

    /// Growing downward can push the panel under the bottom edge. Nudge it
    /// back rather than leaving it somewhere the user cannot grab it.
    private func clampOnScreen() {
        guard let screen = NSScreen.screens.first(where: {
            $0.visibleFrame.intersects(frame)
        }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        var o = frame.origin
        o.x = min(max(o.x, v.minX), v.maxX - frame.width)
        o.y = min(max(o.y, v.minY), v.maxY - frame.height)
        if o != frame.origin { setFrameOrigin(o) }
    }

    // MARK: - Position

    private func savePosition() {
        let origin = frame.origin
        UserDefaults.standard.set(["x": origin.x, "y": origin.y], forKey: Self.originKey)
    }

    private func restorePosition() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.originKey),
           let x = saved["x"] as? CGFloat, let y = saved["y"] as? CGFloat {
            let candidate = NSPoint(x: x, y: y)
            // A saved position can land off-screen after a monitor is
            // unplugged, or after the avatar grows and its top-left anchor
            // pushes it under the edge. Only honour it if it still intersects
            // a screen; otherwise fall through to the default corner.
            let stillVisible = NSScreen.screens.contains {
                $0.visibleFrame.intersects(NSRect(origin: candidate, size: frame.size))
            }
            if stillVisible {
                setFrameOrigin(candidate)
                return
            }
        }
        moveToDefaultCorner()
    }

    private func moveToDefaultCorner() {
        // NSScreen.main is the screen holding the key window, and an agent app
        // with no key window has none — it returns nil. Relying on it meant
        // this silently did nothing and left the panel at the origin, off the
        // bottom-left corner of the screen with no way to get it back.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 20,
                               y: visible.maxY - frame.height - 20))
    }

    /// Bring it back into view when it has drifted off a disconnected display.
    func resetPosition() {
        moveToDefaultCorner()
        savePosition()
    }
}
