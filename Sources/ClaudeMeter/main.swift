import AppKit

// Top-level code in main.swift is nonisolated, but AppDelegate and everything
// under it is @MainActor. The process entry point is already on the main
// thread, so assert that to bridge into the main-actor world.
MainActor.assumeIsolated {
    let args = CommandLine.arguments

    // Offscreen review mode: render every style in every state to a PNG and
    // exit. The escalation and exception states cannot be reached on demand
    // from live data, and this needs no screen-recording permission.
    if let i = args.firstIndex(of: "--render-grid") {
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("usage: --render-grid <path.png>\n".utf8))
            exit(2)
        }
        // ImageRenderer needs an initialized NSApplication for font and colour
        // resolution, but the app must not present anything.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let ok = RenderGrid.run(to: args[i + 1])
        print(ok ? "wrote \(args[i + 1])" : "render failed")
        exit(ok ? 0 : 1)
    }

    // Same idea for the two surfaces you would otherwise have to click to see.
    if let i = args.firstIndex(of: "--render-ui") {
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("usage: --render-ui <path.png>\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let ok = RenderUI.run(to: args[i + 1])
        print(ok ? "wrote \(args[i + 1])" : "render failed")
        exit(ok ? 0 : 1)
    }

    let app = NSApplication.shared
    // .accessory keeps ClaudeMeter out of the Dock and Cmd+Tab -- the menubar
    // item and the floating avatar are the only surfaces it has.
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
