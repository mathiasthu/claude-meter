import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menubar: MenubarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenubarController()
        menubar = controller
        // A status item cannot be clicked programmatically without
        // Accessibility permission, so this is how the settings window gets
        // opened for a screenshot.
        if CommandLine.arguments.contains("--open-settings") {
            // An .accessory app launched from a background shell cannot
            // reliably raise a window above the frontmost app, so this debug
            // path promotes to a regular app first. The shipping launch never
            // takes this branch.
            NSApp.setActivationPolicy(.regular)
            let args = CommandLine.arguments
            let pane = (args.firstIndex(of: "--settings-pane")).flatMap {
                $0 + 1 < args.count ? args[$0 + 1] : nil
            }
            controller.openSettings(pane: pane)
            NSApp.activate(ignoringOtherApps: true)
        }
        // Same reason: the avatar's popover cannot be opened by a synthetic
        // click either. This one deliberately does NOT promote the activation
        // policy, so it exercises the real .accessory path.
        if CommandLine.arguments.contains("--open-avatar-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { controller.toggleAvatarPopover() }
            }
        }
    }

    /// There are no windows to close, so the default "quit when the last
    /// window goes away" behaviour would kill the agent as soon as the avatar
    /// is hidden.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
