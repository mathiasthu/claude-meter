import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menubar: MenubarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menubar = MenubarController()
    }

    /// There are no windows to close, so the default "quit when the last
    /// window goes away" behaviour would kill the agent as soon as the avatar
    /// is hidden.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
