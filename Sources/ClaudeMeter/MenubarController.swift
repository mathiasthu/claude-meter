import AppKit
import SwiftUI
import Combine

/// Owns the menubar item, the click popover, the settings window, and the
/// floating avatar.
///
/// An `NSObject` because it is both popovers' delegate, and `NSPopoverDelegate`
/// refines `NSObjectProtocol`.
@MainActor
final class MenubarController: NSObject, NSPopoverDelegate {

    private let settings = SettingsStore.shared
    private let store: SnapshotStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    /// A second popover anchored to the floating avatar. Separate from the
    /// menubar one so both can be open independently and neither steals the
    /// other's anchor view.
    ///
    /// A `var`, and replaced after every dismissal rather than reused. An
    /// `NSPopover` anchored to a `.nonactivatingPanel` does not come back from
    /// a programmatic close on this machine: `isShown` stays true, the delegate
    /// is never told, and every later `show(relativeTo:)` quietly does nothing
    /// — so the second ring you clicked opened an empty screen. The four
    /// floating styles never hit it because AppKit dismisses their `.transient`
    /// popover itself on the way in, which leaves it in a state it can be shown
    /// from again.
    private var avatarPopover = NSPopover()
    private let settingsWindow: SettingsWindowController
    private var avatar: AvatarPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObserver: NSKeyValueObservation?
    /// Which ring the avatar popover is currently showing, if it is showing a
    /// ring at all. Held here rather than read off `AvatarUIState`, which the
    /// tap gesture has already updated by the time the click arrives — asking
    /// it "was this the ring that was open?" always answers yes.
    private var shownRing: NotchRing?
    /// Event monitors that dismiss the ring popover. Live only while it is up.
    private var dismissMonitors: [Any] = []
    /// Whether the avatar's popover is up. The controller's own record, and
    /// deliberately not `NSPopover.isShown`.
    ///
    /// Measured on this machine: a popover anchored to a `.nonactivatingPanel`
    /// still reports `isShown == true` after a programmatic `close()`, and
    /// `popoverDidClose` is never delivered for that path at all — AppKit posts
    /// it only when it dismisses the popover itself. Believing either one made
    /// the second click on a ring close something already closed, and the
    /// fourth fail to reopen it. Everything the notification used to be trusted
    /// for is done explicitly in `teardownAvatarPopover()` instead.
    private var avatarPopoverShown = false
    /// The style, edge and display the popover was anchored against. A change
    /// to any of the three strands it: a `SessionListView` left over from a
    /// creature is anchored to a `spriteBounds()` that is now the whole strip,
    /// and a ring popover that survives a flip to the other edge — or to the
    /// other monitor — points at a window that has moved.
    ///
    /// The display is remembered here for the same reason the edge is. It is
    /// read only inside `AvatarPanel.dockScreen()`, so nothing outside the
    /// panel used to notice it moving, and moving it walks the strip across
    /// monitors — the largest move the window ever makes.
    private var lastStyle: AvatarStyleID
    private var lastEdge: NotchEdge
    private var lastScreenID: UInt32

    override init() {
        lastStyle = settings.styleID
        lastEdge = settings.notchEdge
        lastScreenID = settings.notchScreenID
        store = SnapshotStore(settings: settings)
        settingsWindow = SettingsWindowController(settings: settings)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        avatarPopover.behavior = .transient
        // Both are delegated here so their content controllers can be released
        // on close -- see popoverDidClose.
        popover.delegate = self
        avatarPopover.delegate = self

        // The store republishes on file changes and once a second; settings
        // change what the title shows. The title has to follow all three.
        store.$sessions
            .combineLatest(store.$tick)
            .sink { [weak self] _ in self?.refreshStatusItem() }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.settingsChanged() }
            }
            .store(in: &cancellables)
        // The status item is now only rebuilt when its contents change, and the
        // appearance is not one of the things it derives them from -- the icon
        // resolves labelColor at draw time and the title colour comes from a
        // dynamic NSColor. Switching between light and dark therefore changes
        // nothing this class can see, so the cache is dropped explicitly rather
        // than being refreshed a second later by a tick that no longer arrives.
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                self?.rendered = nil
                self?.refreshStatusItem()
            }
        }

        refreshStatusItem()
        if settings.avatarVisible { showAvatar() }
    }

    // MARK: - Status item

    /// Everything the status item shows, as the values it is derived from.
    ///
    /// The store republishes once a second so that countdowns and ages cannot
    /// go quietly wrong, but none of the strings on the button move that fast:
    /// `Fmt` rounds percentages to whole numbers and countdowns and ages to
    /// whole minutes, so a title is typically identical to the last one
    /// fifty-nine times out of sixty. Building a fresh `NSImage` and a fresh
    /// `NSAttributedString` each time, and handing both to AppKit, was doing
    /// layout and drawing work in the menu bar once a second to arrive back at
    /// the pixels already on screen.
    private struct StatusItemContents: Equatable {
        let state: MeterState
        let value: Double?
        let title: String
        let display: MenubarDisplay
        let thresholds: Thresholds
    }

    private var rendered: StatusItemContents?

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let state = store.state
        let value = store.menubarValue
        let display = settings.menubarDisplay
        let next = StatusItemContents(
            state: state,
            value: value,
            title: display.showsText ? " " + titleText(state: state, value: value) : "",
            display: display,
            thresholds: settings.thresholds)
        guard next != rendered else { return }
        rendered = next

        button.image = display.showsIcon
            ? MenubarIcon.image(state: state, percentage: value,
                                thresholds: settings.thresholds)
            : nil
        button.imagePosition = display.showsText ? .imageLeading : .imageOnly
        button.attributedTitle = NSAttributedString(
            string: next.title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: titleColor(state),
            ])
        button.toolTip = state.headline
    }

    /// Degrades from the right as data disappears:
    /// "5h 62% · 3h07m" → "5h 62%" → "62%" → "—".
    private func titleText(state: MeterState, value: Double?) -> String {
        guard let value else { return "—" }
        var s = ""
        let prefix = settings.menubarMetric.prefix
        if !prefix.isEmpty { s += prefix + " " }
        s += Fmt.percent(value)
        if state == .stale || state == .asleep {
            // An age, never a countdown — a countdown implies the number
            // beside it is live.
            if let age = store.newestAge { s += " · \(Fmt.age(age)) ago" }
        } else if settings.menubarCountdown,
                  let reset = Fmt.countdown(to: store.menubarResetsAt) {
            s += " · \(reset)"
        }
        return s
    }

    private func titleColor(_ state: MeterState) -> NSColor {
        switch state {
        case .critical: return .systemRed
        case .strained: return .systemOrange
        // Everything else stays in the menubar's own ink. Dormant states used
        // to drop to tertiaryLabelColor, which is roughly 25% opacity — the
        // intent was "do not shout when nothing is happening", but against a
        // dark menubar it was unreadable rather than quiet. Dormancy is
        // already carried without colour: the icon greys out, and the title
        // ends in an age ("· 1m ago") where a live one carries a countdown.
        default: return .labelColor
        }
    }

    // MARK: - Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(sender)
        } else {
            togglePopover(sender)
        }
    }

    /// Builds the breakdown both popovers show, and tells the popover how big
    /// it is going to be.
    ///
    /// The size is not decoration. Without it the popover keeps its 320×320
    /// default until SwiftUI has laid the list out, and AppKit positions the
    /// popover from that stale number: the balloon it actually drew was 296 pt
    /// wide and however tall the sessions made it, floating inside a window
    /// sized for something else, which put ~40 pt of empty air between the
    /// arrow and whatever the popover was anchored to. Laying the hosting view
    /// out here and handing over its fitting size makes the window the size of
    /// the balloon, so the arrow lands where it was aimed.
    private func install(sessionListInto popover: NSPopover) {
        let controller = NSHostingController(
            rootView: SessionListView(
                store: store,
                settings: settings,
                onToggleAvatar: { [weak self] in self?.toggleAvatar() },
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        popover.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        let fitted = controller.view.fittingSize
        if fitted.width > 1, fitted.height > 1 { popover.contentSize = fitted }
    }

    /// The notch's popover. A near-clone of `install(sessionListInto:)`, and
    /// it must keep all three of its steps — fresh hosting controller, forced
    /// layout, `contentSize` — for the reason documented above: skipping the
    /// last one reproduces the 320x320 window with the arrow pointing at air.
    private func install(breakdownInto popover: NSPopover, selecting ring: NotchRing?) {
        let controller = NSHostingController(
            rootView: NotchBreakdownView(
                store: store,
                settings: settings,
                selected: ring,
                onOpenSettings: { [weak self] in self?.openSettings() }
            )
        )
        popover.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        let fitted = controller.view.fittingSize
        if fitted.width > 1, fitted.height > 1 { popover.contentSize = fitted }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        install(sessionListInto: popover)
        store.reload()
        store.beginFineUpdates()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Lets go of the hosting controller the moment the popover is dismissed.
    ///
    /// `contentViewController` is a strong reference, and until this existed
    /// nothing ever cleared it: a popover closed at 11am still owned a live
    /// `NSHostingController` at 6pm, and SwiftUI kept re-evaluating its body
    /// against every store update for the rest of the day, laying out and
    /// drawing a 296 pt panel nobody could see. Opening the dropdown once was
    /// the permanent step from roughly 1.7% of a core to 4.6%, and opening the
    /// avatar's as well added a second copy. Both popovers build a fresh
    /// controller on the way in, so there is nothing to preserve here.
    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover else { return }
        // AppKit dismissed the avatar's popover itself — a `.transient` sprite
        // popover losing focus. Same teardown as the explicit path, and the
        // flag inside it is what stops the two ever running twice.
        guard closed !== avatarPopover else {
            teardownAvatarPopover(alreadyClosed: true)
            return
        }
        closed.contentViewController = nil
        store.endFineUpdates()
    }

    /// Puts the avatar's popover away and undoes everything showing it did.
    ///
    /// Explicit rather than left to `popoverDidClose`, which does not arrive
    /// for a programmatic close. Guarded so the delegate callback and this
    /// cannot both run: `endFineUpdates()` is balanced against one
    /// `beginFineUpdates()`, and a second call would take a tick away from
    /// whoever else is holding one.
    private func teardownAvatarPopover(alreadyClosed: Bool = false) {
        guard avatarPopoverShown else { return }
        avatarPopoverShown = false
        removeDismissMonitors()
        let old = avatarPopover
        // Detached first: the replacement below must not be sent this one's
        // close, or the teardown runs a second time against a popover that was
        // never shown.
        old.delegate = nil
        // `close()`, not `performClose(nil)`: the animated dismissal is still
        // running when a ring-to-ring switch asks for the next popover.
        if !alreadyClosed { old.close() }
        old.contentViewController = nil
        avatarPopover = NSPopover()
        avatarPopover.delegate = self
        avatar?.clearPopoverAnchor()
        store.endFineUpdates()
        shownRing = nil
        avatar?.ui.selectedRing = nil
    }

    private func showMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: settings.avatarVisible ? "Hide avatar" : "Show avatar",
                     action: #selector(toggleAvatarMenu), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Reset avatar position",
                     action: #selector(resetAvatarPosition), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…",
                     action: #selector(openSettingsMenu), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Reveal snapshots in Finder",
                     action: #selector(revealState), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ClaudeMeter",
                     action: #selector(quit), keyEquivalent: "q")
            .target = self

        // Assigning `menu` permanently would take over left-click too; showing
        // it for this one event keeps left-click on the popover.
        statusItem.menu = menu
        sender.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Avatar

    private func settingsChanged() {
        refreshStatusItem()
        let styleMoved = settings.styleID != lastStyle
        let edgeMoved = settings.notchEdge != lastEdge
        let screenMoved = settings.notchScreenID != lastScreenID
        // Whether the panel is docked on either side of this change is what
        // decides whether the window is about to be picked up and put
        // somewhere else. `AvatarPanel.resizeToFit()` re-docks whenever the
        // new style is docked and restores the floating origin whenever the
        // old one was, and those two branches are the only places a settings
        // change moves the window behind the popover's back. A style swap
        // between two floating characters, or an edge the user flips while no
        // strip is on screen, moves nothing and must not cost a rebuild —
        // this fires on every settings tick.
        let dockMoves = lastStyle.isDocked || settings.styleID.isDocked
        if styleMoved || edgeMoved || screenMoved {
            lastStyle = settings.styleID
            lastEdge = settings.notchEdge
            lastScreenID = settings.notchScreenID
            // The anchor the popover was placed against has just stopped
            // meaning what it meant. Scale and opacity are deliberately not on
            // this list — those may move with it open.
            teardownAvatarPopover()
            if dockMoves { rebuildAvatar() }
        }
        if settings.avatarVisible { showAvatar() } else { hideAvatar() }
    }

    /// The displays changed under a docked strip, and `AvatarPanel` handed the
    /// decision here rather than quietly re-docking itself.
    ///
    /// Unplugging a monitor, closing the lid or rearranging the arrangement in
    /// System Settings all move the strip, and none of them is a settings
    /// change — nothing in `settingsChanged()` can see them. Before this, the
    /// panel re-docked in place and the next ring click opened its popover
    /// against the display that had just gone away.
    ///
    /// The hop onto the next main-actor turn is not decoration: this is
    /// invoked from a closure the panel itself owns, and `rebuildAvatar()`
    /// drops the last reference to it.
    private func displaysChanged() {
        guard settings.styleID.isDocked else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.teardownAvatarPopover()
            self.rebuildAvatar()
            if self.settings.avatarVisible { self.showAvatar() }
        }
    }

    private func toggleAvatar() {
        settings.avatarVisible.toggle()
        if popover.isShown { popover.performClose(nil) }
        teardownAvatarPopover()
    }

    private func showAvatar() {
        if avatar == nil {
            avatar = AvatarPanel(
                store: store, settings: settings,
                onClick: { [weak self] ring in self?.toggleAvatarPopover(ring: ring) },
                onDisplaysChanged: { [weak self] in self?.displaysChanged() })
        }
        // orderFrontRegardless, not makeKeyAndOrderFront: showing the widget
        // must not steal focus from the terminal you are working in.
        avatar?.orderFrontRegardless()
    }

    /// Drops the avatar panel so the next `showAvatar()` builds a fresh one.
    private func rebuildAvatar() {
        avatar?.orderOut(nil)
        avatar = nil
    }

    private func hideAvatar() {
        teardownAvatarPopover()
        avatar?.orderOut(nil)
    }

    /// Clicking the avatar opens the breakdown for whatever was clicked: the
    /// menubar's session list for a sprite, the notch's three-row panel for a
    /// ring.
    ///
    /// The app has to be activated first: the avatar lives in a
    /// `.nonactivatingPanel`, so clicking it does not make the app active, and
    /// a `.transient` popover belonging to an inactive app dismisses itself
    /// immediately. This is an explicit click, so taking focus is expected.
    func toggleAvatarPopover(ring requested: NotchRing? = nil) {
        guard let avatar else { return }
        // A ring only means anything on a docked style. This guards the
        // `--ring` debug flag and any click that outlives a style switch:
        // `ringRect` is arithmetic and will happily answer for a creature, at a
        // y 400 pt outside an 84 pt window.
        let ring = settings.styleID.isDocked ? requested : nil

        // Clicking the ring that is already open closes it; clicking a
        // different one switches without a visit to "closed" in between.
        if avatarPopoverShown {
            let sameTarget = ring == shownRing
            teardownAvatarPopover()
            if sameTarget { return }
        }

        if let ring {
            // .applicationDefined, not .transient. Ring-to-ring is the primary
            // interaction, and a transient popover dismisses on the way in:
            // whether the mouse-down that closes it also reaches the tap
            // gesture that would reopen it is a race, which shows up as
            // "clicking the next ring closed it instead of switching".
            // Dismissal is done by hand below instead.
            avatarPopover.behavior = .applicationDefined
            avatarPopover.appearance = NSAppearance(named: .vibrantDark)
            install(breakdownInto: avatarPopover, selecting: ring)
        } else {
            avatarPopover.behavior = .transient
            avatarPopover.appearance = nil
            install(sessionListInto: avatarPopover)
        }

        store.reload()
        store.beginFineUpdates()
        NSApp.activate(ignoringOtherApps: true)

        if let ring {
            // Aimed at the ring rather than at the artwork: `spriteBounds()`
            // measures painted pixels, and the strip is opaque across its whole
            // band, so it would answer "the entire window" for every ring. The
            // arrow leaves by the inner edge, which flips with the dock.
            let anchor = avatar.makePopoverAnchor(avatar.ringRect(ring))
            avatarPopover.show(relativeTo: anchor.bounds, of: anchor,
                               preferredEdge: settings.notchEdge == .right ? .minX : .maxX)
        } else {
            // Anchored to the painted sprite rather than to the window: the
            // styles leave transparent margin inside their canvas, and
            // anchoring to the window edge left the popover floating well clear
            // of the artwork. The hosting view is flipped, so .minY is the
            // visual bottom edge. AppKit flips it automatically when the avatar
            // is parked low.
            let anchor = avatar.makePopoverAnchor(avatar.spriteBounds())
            avatarPopover.show(relativeTo: anchor.bounds, of: anchor,
                               preferredEdge: .minY)
        }
        avatarPopover.contentViewController?.view.window?.makeKey()

        avatarPopoverShown = true
        shownRing = ring
        avatar.ui.selectedRing = ring
        if ring != nil { installDismissMonitors() }
    }

    // MARK: - Dismissing the ring popover

    /// What `.transient` would have done, minus the race it loses.
    ///
    /// A click anywhere that is not the strip and not the popover closes it.
    /// A click on the strip is left alone deliberately — the tap gesture is
    /// about to decide whether that was the same ring (close) or a different
    /// one (switch), and this must not answer first.
    private func installDismissMonitors() {
        removeDismissMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: {
            [weak self] event in
            MainActor.assumeIsolated { self?.dismissIfOutside(event) }
        }) {
            dismissMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: {
            [weak self] event in
            MainActor.assumeIsolated { self?.dismissIfOutside(event) }
            return event
        }) {
            dismissMonitors.append(local)
        }
    }

    private func removeDismissMonitors() {
        for m in dismissMonitors { NSEvent.removeMonitor(m) }
        dismissMonitors.removeAll()
    }

    private func dismissIfOutside(_ event: NSEvent) {
        guard avatarPopoverShown else { return }
        // A global monitor only ever sees clicks meant for another app, and
        // those carry no window of ours — so a nil window is already outside.
        if let window = event.window {
            if window === avatar { return }
            if window === avatarPopover.contentViewController?.view.window { return }
        }
        teardownAvatarPopover()
    }

    /// Also called at launch by `--open-settings`, which exists so the window
    /// can be screenshotted without clicking the status item — a status item
    /// cannot be clicked programmatically without Accessibility permission.
    func openSettings(pane: String? = nil) {
        if popover.isShown { popover.performClose(nil) }
        if let pane { settingsWindow.select(pane: pane) }
        settingsWindow.show()
    }

    /// Debug affordance for the same screenshot path: the settings window
    /// normally closes as soon as it stops being key, which would shut it the
    /// moment focus goes back to the shell that is about to photograph it.
    func keepSettingsOpenWhileScreenshotting() {
        settingsWindow.closesWhenDeactivated = false
    }

    // MARK: - Menu actions

    @objc private func toggleAvatarMenu() { toggleAvatar() }
    @objc private func openSettingsMenu() { openSettings() }

    @objc private func resetAvatarPosition() {
        settings.avatarVisible = true
        showAvatar()
        avatar?.resetPosition()
    }

    @objc private func revealState() {
        NSWorkspace.shared.selectFile(nil,
            inFileViewerRootedAtPath: SnapshotStore.sessionsDirectory.path)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
