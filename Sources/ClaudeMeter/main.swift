import AppKit

// Top-level code in main.swift is nonisolated, but AppDelegate and everything
// under it is @MainActor. The process entry point is already on the main
// thread, so assert that to bridge into the main-actor world.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    // .accessory keeps ClaudeMeter out of the Dock and Cmd+Tab -- the menubar
    // item and the floating avatar are the only surfaces it has.
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
