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
            onGrab: { [weak self] mouse in self?.grab(at: mouse) },
            onDrag: { [weak self] mouse in self?.dragTo(mouse) }))
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
        // window itself, not just its contents. objectWillChange fires in
        // willSet, so the property is still the old one here; the hop onto the
        // next main-actor turn is what makes the new value readable, and
        // resizeToFit() forces the layout itself once it gets there.
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

    /// Where the panel's origin sat relative to the pointer when the drag
    /// started. Held for the length of one drag so every subsequent position is
    /// derived from an absolute mouse reading rather than from the last one.
    private var grabOffset: NSSize?

    private func grab(at mouse: NSPoint) {
        grabOffset = NSSize(width: frame.origin.x - mouse.x,
                            height: frame.origin.y - mouse.y)
    }

    /// Places the panel under the pointer, and remembers where it landed.
    ///
    /// This is anchored rather than incremental for a reason that cost a real
    /// bug: `setFrameOrigin` quantises to whole points by flooring, so feeding
    /// it a running sum of mouse deltas throws away the fraction on every
    /// event and never gets it back. Floor biases that loss the same way every
    /// time, so the avatar crept down and to the left no matter which way it
    /// was dragged — measured at 194 pt left and 190 pt down over one drag of
    /// 529 events. Re-deriving the origin from the pointer each event makes
    /// the error non-cumulative, and lets a dropped or restarted gesture
    /// correct itself on the next event instead of lagging forever.
    ///
    /// Not clamped mid-drag — the user is allowed to park it half off an edge
    /// if they want; only automatic resizes get pulled back.
    private func dragTo(_ mouse: NSPoint) {
        guard let offset = grabOffset else { return }
        setFrameOrigin(NSPoint(x: mouse.x + offset.width, y: mouse.y + offset.height))
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
    ///
    /// The layout pass is not optional. This runs one main-actor turn after
    /// the setting changed, and SwiftUI schedules its own re-evaluation of the
    /// body independently, so reading `fittingSize` on arrival describes
    /// whichever style the hosting view was last laid out for. With the
    /// settings window open that was measured as the *previous* style on every
    /// switch — 84×84 asked for the pill, 232×52.5 asked for the face.
    ///
    /// Forcing the layout here also collapses the resize and the first draw of
    /// the new style into the same turn, which is what stops the new artwork
    /// being painted into a box still sized for the old one and then having
    /// the window resized around it.
    private func resizeToFit() {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        guard fitted.width > 1, fitted.height > 1 else { return }
        if abs(fitted.width - frame.width) > 0.5
            || abs(fitted.height - frame.height) > 0.5 {
            // Keep the top-left corner planted: growing downward from where the
            // user parked it is less surprising than growing from the origin.
            let top = frame.maxY
            setFrame(NSRect(x: frame.minX, y: top - fitted.height,
                            width: fitted.width, height: fitted.height),
                     display: true)
        }
        // Both of these are outside the size test on purpose. Laying the
        // hosting view out above lets AppKit size the window to its new
        // intrinsic size before this point, which leaves the branch above with
        // nothing left to do — but the panel has still changed size, so it can
        // still be hanging off an edge and it still has stale pixels to lose.
        clampOnScreen()
        repaintContents()
    }

    /// The box the artwork actually paints into, in the content view's
    /// coordinates, or the whole content view when nothing can be measured.
    ///
    /// Every style draws inside a canvas larger than its silhouette — the pixel
    /// creature's body starts 9 pt down a 48 pt grid, and both creatures leave
    /// room at the sides for poses that reach. With the plate off that padding
    /// is transparent, so a popover anchored to the window edge opens a
    /// visible gap above the sprite: at 1.75× the empty band alone is ~30 pt,
    /// and the popover's own shadow margin doubles it.
    ///
    /// Measuring the pixels rather than hard-coding per-style insets keeps this
    /// honest across styles, scales, and the states that change the silhouette
    /// (the pill's text, the creature's raised sunglasses).
    func spriteBounds() -> NSRect {
        let full = host.bounds
        guard let rep = host.bitmapImageRepForCachingDisplay(in: full) else { return full }
        host.cacheDisplay(in: full, to: rep)
        guard let data = rep.bitmapData, rep.bitsPerSample == 8,
              rep.samplesPerPixel == 4, rep.pixelsWide > 0, rep.pixelsHigh > 0
        else { return full }

        // Ignore the near-transparent fringe: the artwork carries a drop shadow
        // that spreads a couple of points past the silhouette, and anchoring to
        // the shadow would put the gap back.
        let cutoff = 48
        var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1
        let alphaFirst = rep.bitmapFormat.contains(.alphaFirst)
        for y in 0..<rep.pixelsHigh {
            let row = data + y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide {
                let px = row + x * 4
                let alpha = Int(px[alphaFirst ? 0 : 3])
                guard alpha > cutoff else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return full }

        // The bitmap is in device pixels; the caller wants points. Rows run
        // top-down, which is also how the hosting view's flipped coordinates
        // run, so only the scale has to be undone.
        let sx = full.width / CGFloat(rep.pixelsWide)
        let sy = full.height / CGFloat(rep.pixelsHigh)
        return NSRect(x: CGFloat(minX) * sx, y: CGFloat(minY) * sy,
                      width: CGFloat(maxX - minX + 1) * sx,
                      height: CGFloat(maxY - minY + 1) * sy)
    }

    /// Repaints the whole content area after a resize.
    ///
    /// The window is borderless with a clear background and `isOpaque` off, so
    /// there is no opaque backing to cover what the previous style left in the
    /// area a resize exposes. Redrawing the whole rect costs one pass over a
    /// sprite a couple of hundred points across, which is cheap next to a
    /// corner of the old artwork surviving the swap.
    private func repaintContents() {
        host.setNeedsDisplay(host.bounds)
        viewsNeedDisplay = true
        displayIfNeeded()
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
