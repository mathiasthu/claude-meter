import AppKit
import SwiftUI

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
    /// Held here so the card's hover/pulse state survives re-renders -- see
    /// AvatarUIState for why this is not `@State`.
    private let ui = AvatarUIState()

    init(store: SnapshotStore, onClose: @escaping () -> Void) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 156, height: 56),
            // .borderless drops the title bar; .nonactivatingPanel is what
            // keeps clicks from stealing focus.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        // Visible on every Space, and ignored by Mission Control's window
        // shuffling -- it should feel pinned to the screen, not to a desktop.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Drag from anywhere on the card; there is no title bar to grab.
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // Borderless panels cannot become key by default, and this one should
        // not want to -- nothing in it takes text input.
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false

        let host = NSHostingView(
            rootView: AvatarFace(store: store, ui: ui, onClose: onClose))
        host.frame = contentRect(forFrameRect: frame)
        host.autoresizingMask = [.width, .height]
        contentView = host

        restorePosition()

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        }
    }

    deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
    }

    /// Never becomes key: typing always goes to the app underneath.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

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
            // unplugged, which would hide the widget with no way to get it
            // back. Only honour it if it still intersects a screen.
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
        guard let screen = NSScreen.main else { return }
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
