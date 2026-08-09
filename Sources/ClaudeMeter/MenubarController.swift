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
    private let avatarPopover = NSPopover()
    private let settingsWindow: SettingsWindowController
    private var avatar: AvatarPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObserver: NSKeyValueObservation?

    override init() {
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

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.contentViewController = NSHostingController(
            rootView: SessionListView(
                store: store,
                settings: settings,
                onToggleAvatar: { [weak self] in self?.toggleAvatar() },
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
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
        closed.contentViewController = nil
        store.endFineUpdates()
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
        if settings.avatarVisible { showAvatar() } else { hideAvatar() }
    }

    private func toggleAvatar() {
        settings.avatarVisible.toggle()
        if popover.isShown { popover.performClose(nil) }
        if avatarPopover.isShown { avatarPopover.performClose(nil) }
    }

    private func showAvatar() {
        if avatar == nil {
            avatar = AvatarPanel(
                store: store, settings: settings,
                onClick: { [weak self] in self?.toggleAvatarPopover() })
        }
        // orderFrontRegardless, not makeKeyAndOrderFront: showing the widget
        // must not steal focus from the terminal you are working in.
        avatar?.orderFrontRegardless()
    }

    private func hideAvatar() {
        if avatarPopover.isShown { avatarPopover.performClose(nil) }
        avatar?.orderOut(nil)
    }

    /// Clicking the avatar opens the same breakdown the menubar shows.
    ///
    /// The app has to be activated first: the avatar lives in a
    /// `.nonactivatingPanel`, so clicking it does not make the app active, and
    /// a `.transient` popover belonging to an inactive app dismisses itself
    /// immediately. This is an explicit click, so taking focus is expected.
    func toggleAvatarPopover() {
        guard let anchor = avatar?.contentView else { return }
        if avatarPopover.isShown {
            avatarPopover.performClose(nil)
            return
        }
        avatarPopover.contentViewController = NSHostingController(
            rootView: SessionListView(
                store: store,
                settings: settings,
                onToggleAvatar: { [weak self] in self?.toggleAvatar() },
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        store.reload()
        store.beginFineUpdates()
        NSApp.activate(ignoringOtherApps: true)
        // The hosting view is flipped, so .minY is the visual bottom edge.
        // AppKit flips it automatically when the avatar is parked low.
        avatarPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        avatarPopover.contentViewController?.view.window?.makeKey()
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
