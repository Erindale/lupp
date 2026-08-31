import AppKit
import Foundation

/// One background colour for the entire window.
///
/// Authored in sRGB, because that is the space the chrome is designed in, and
/// converted to linear for the Metal drawable — which renders into an extended
/// *linear* space. Handing the same number to both would make the canvas
/// visibly lighter than the title bar it is meant to be continuous with.
enum Theme {
    static let backgroundSRGB: CGFloat = 0.26

    static var background: NSColor {
        NSColor(srgbRed: backgroundSRGB, green: backgroundSRGB, blue: backgroundSRGB, alpha: 1)
    }

    static var backgroundLinear: Double {
        let v = Double(backgroundSRGB)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Scope panels sit a touch darker so the traces read against them.
    static var scopeBackground: NSColor {
        NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1)
    }

    static let panelWidth: CGFloat = 320
}
