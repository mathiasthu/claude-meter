import AppKit
import SwiftUI
import Combine

/// Owns the menubar item, the click popover, and the floating avatar.
///
/// The status item shows the 5-hour window, because that is the number you
/// cannot do anything about once it runs out -- context can always be
/// reclaimed with /compact.
@MainActor
final class MenubarController {

    private static let avatarVisibleKey = "avatar.visible"

    private let store = SnapshotStore()
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var avatar: AvatarPanel?
    private var cancellables: Set<AnyCancellable> = []

    private var avatarVisible: Bool {
        get {
            // Default to showing it: someone who launches this wants the widget.
            UserDefaults.standard.object(forKey: Self.avatarVisibleKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.avatarVisibleKey) }
    }

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: SessionListView(
                store: store,
                avatarVisible: avatarVisible,
                onToggleAvatar: { [weak self] in self?.toggleAvatar() },
                onQuit: { NSApp.terminate(nil) }
            )
        )

        // The store republishes on every file change and once a second; the
        // title has to follow both, so redraw on either.
        store.$sessions
            .combineLatest(store.$tick)
            .sink { [weak self] _ in self?.refreshTitle() }
            .store(in: &cancellables)

        refreshTitle()
        if avatarVisible { showAvatar() }
    }

    // MARK: - Status item

    private func refreshTitle() {
        guard let button = statusItem.button else { return }
        let pct = store.accountLimits?.limits.fiveHour?.usedPercentage
        let text = "5h \(Fmt.percent(pct))"

        // NSColor rather than the SwiftUI palette: the status item title is
        // AppKit, and it needs to survive light/dark menubar backgrounds.
        let color: NSColor = {
            switch store.mood {
            case .alarmed:  return .systemRed
            case .sweating: return .systemOrange
            case .asleep, .stale: return .tertiaryLabelColor
            case .calm, .focused: return .labelColor
            }
        }()

        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: color,
            ]
        )
    }

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
        // Rebuild the root view so the footer's avatar label reflects the
        // current state -- SessionListView takes it as a plain value.
        popover.contentViewController = NSHostingController(
            rootView: SessionListView(
                store: store,
                avatarVisible: avatarVisible,
                onToggleAvatar: { [weak self] in self?.toggleAvatar() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        store.reload()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: avatarVisible ? "Hide avatar" : "Show avatar",
                     action: #selector(toggleAvatarMenu), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Reset avatar position",
                     action: #selector(resetAvatarPosition), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal snapshots in Finder",
                     action: #selector(revealState), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ClaudeMeter",
                     action: #selector(quit), keyEquivalent: "q")
            .target = self

        // menu(_:) would make the menu permanent on left-click too; showing it
        // for this one event keeps left-click on the popover.
        statusItem.menu = menu
        sender.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Avatar

    private func toggleAvatar() {
        avatarVisible.toggle()
        if avatarVisible { showAvatar() } else { hideAvatar() }
        if popover.isShown { popover.performClose(nil) }
    }

    private func showAvatar() {
        if avatar == nil {
            avatar = AvatarPanel(store: store) { [weak self] in
                // The card's own close button: hide, and remember that.
                self?.avatarVisible = false
                self?.hideAvatar()
            }
        }
        // orderFrontRegardless, not makeKeyAndOrderFront: showing the widget
        // must not steal focus from the terminal you are working in.
        avatar?.orderFrontRegardless()
    }

    private func hideAvatar() {
        avatar?.orderOut(nil)
    }

    // MARK: - Menu actions

    @objc private func toggleAvatarMenu() { toggleAvatar() }

    @objc private func resetAvatarPosition() {
        avatar?.resetPosition()
        if !avatarVisible { avatarVisible = true }
        showAvatar()
    }

    @objc private func revealState() {
        NSWorkspace.shared.selectFile(nil,
            inFileViewerRootedAtPath: SnapshotStore.sessionsDirectory.path)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
