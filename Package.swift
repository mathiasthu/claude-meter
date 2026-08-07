// swift-tools-version:5.10
import PackageDescription

// ClaudeMeter is a menubar agent plus a floating avatar panel. It reads the
// snapshots that bin/claude-meter-collect publishes from Claude Code's status
// line -- it never talks to any API, holds no credentials, and has no
// dependencies beyond AppKit/SwiftUI.
//
// Built into an .app bundle by scripts/build-app.sh; running the bare
// executable from .build/ works but gives up LSUIElement, so macOS shows a
// Dock icon.
let package = Package(
    name: "claude-meter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeMeter", targets: ["ClaudeMeter"]),
    ],
    targets: [
        .executableTarget(name: "ClaudeMeter"),
    ]
)
