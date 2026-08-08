import SwiftUI
import AppKit

/// The colour tokens from the visual system spec.
///
/// Every token is a dynamic `NSColor`, so it resolves against whatever
/// appearance it is drawn into — the avatar sits over unpredictable wallpaper
/// and the menubar flips with the system, and neither gets to be re-rendered by
/// hand when the appearance changes.
enum Tokens {

    // Escalation ramp. Calm is deliberately a grey rather than a green: when
    // everything is fine the avatar should be close to invisible, and a green
    // "all good" light is still a light.
    static let calm     = dyn(light: 0x8E8E93, dark: 0x98989D)  // systemGray
    static let focused  = dyn(light: 0xFFCC00, dark: 0xFFD60A)  // systemYellow
    static let strained = dyn(light: 0xFF9500, dark: 0xFF9F0A)  // systemOrange
    static let critical = dyn(light: 0xFF3B30, dark: 0xFF453A)  // systemRed

    /// Asleep, stale, missing. Never used for a live reading, so a grey mark is
    /// always safe to read as "this is not a current value".
    static let dormant  = dyn(light: 0xC7C7CC, dark: 0x636366)

    /// Strokes, needles, glyphs, text.
    static let ink      = dyn(light: 0x1D1D1F, dark: 0xF5F5F7)
    static let inkSoft  = NSColor.dynamic(
        light: NSColor(white: 0, alpha: 0.5),
        dark:  NSColor(white: 1, alpha: 0.55))

    /// The disc or squircle every avatar sits on, so it survives any wallpaper.
    static let ground   = NSColor.dynamic(
        light: NSColor(white: 1, alpha: 0.92),
        dark:  NSColor(red: 50/255, green: 50/255, blue: 54/255, alpha: 0.92))
    static let hairline = NSColor.dynamic(
        light: NSColor(white: 0, alpha: 0.14),
        dark:  NSColor(white: 1, alpha: 0.18))

    /// The pixel creature's resting body colour. Not part of the state ramp —
    /// only escalation re-tints it, so orange at rest reads as "fine".
    static let brandOrange = dyn(light: 0xD97757, dark: 0xD97757)

    // SwiftUI-side accessors.
    static var calmC: Color     { Color(nsColor: calm) }
    static var focusedC: Color  { Color(nsColor: focused) }
    static var strainedC: Color { Color(nsColor: strained) }
    static var criticalC: Color { Color(nsColor: critical) }
    static var dormantC: Color  { Color(nsColor: dormant) }
    static var inkC: Color      { Color(nsColor: ink) }
    static var inkSoftC: Color  { Color(nsColor: inkSoft) }
    static var groundC: Color   { Color(nsColor: ground) }
    static var hairlineC: Color { Color(nsColor: hairline) }
    static var brandOrangeC: Color { Color(nsColor: brandOrange) }

    private static func dyn(light: Int, dark: Int) -> NSColor {
        NSColor.dynamic(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }
}

extension NSColor {
    /// Appearance-reactive colour. `bestMatch` rather than a name comparison,
    /// because the accessibility appearances (increased contrast, vibrancy)
    /// are distinct names that still need to resolve to light or dark.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green:   CGFloat((hex >> 8) & 0xFF) / 255,
                  blue:    CGFloat(hex & 0xFF) / 255,
                  alpha:   1)
    }
}

// MARK: - Type

enum Typo {
    /// Numbers are always monospaced — a percentage that shifts width as it
    /// ticks is the fastest way to make a HUD feel unstable.
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> Font {
        Font(NSFont.monospacedSystemFont(ofSize: size, weight: weight))
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
