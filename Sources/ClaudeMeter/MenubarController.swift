import AppKit
import SwiftUI
import Combine

/// Owns the menubar item, the click popover, the settings window, and the
/// floating avatar.
@MainActor
final class MenubarController {

    private let settings = SettingsStore.shared
    private let store: SnapshotStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let settingsWindow: SettingsWindowController
    private var avatar: AvatarPanel?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        store = SnapshotStore(settings: settings)
        settingsWindow = SettingsWindowController(settings: settings)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient

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

        refreshStatusItem()
        if settings.avatarVisible { showAvatar() }
    }

    // MARK: - Status item

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let state = store.state
        let value = store.menubarValue

        button.image = settings.menubarDisplay.showsIcon
            ? MenubarIcon.image(state: state, percentage: value,
                                thresholds: settings.thresholds)
            : nil
        button.imagePosition = settings.menubarDisplay.showsText ? .imageLeading : .imageOnly

        if settings.menubarDisplay.showsText {
            button.attributedTitle = NSAttributedString(
                string: " " + titleText(state: state, value: value),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: titleColor(state),
                ])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
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
        // Calm and focused stay in the menubar's own ink: colour here is for
        // things worth looking at, and "fine" is not one of them.
        case .calm, .focused: return .labelColor
        default: return .tertiaryLabelColor
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
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
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
    }

    private func showAvatar() {
        if avatar == nil {
            avatar = AvatarPanel(store: store, settings: settings) { [weak self] in
                // The card's own close button: hide, and remember that.
                self?.settings.avatarVisible = false
            }
        }
        // orderFrontRegardless, not makeKeyAndOrderFront: showing the widget
        // must not steal focus from the terminal you are working in.
        avatar?.orderFrontRegardless()
    }

    private func hideAvatar() {
        avatar?.orderOut(nil)
    }

    private func openSettings() {
        if popover.isShown { popover.performClose(nil) }
        settingsWindow.show()
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
