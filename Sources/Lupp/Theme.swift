import AppKit
import Foundation

/// Every colour in the window, derived from one number.
///
/// The backdrop is adjustable (right-drag on the canvas) because the right
/// surround depends on the image — a bright one makes a dark frame look washed
/// out. Everything else is computed from it rather than being a fixed palette,
/// so the whole app moves together instead of the canvas drifting away from its
/// own chrome.
///
/// Authored in sRGB, since that is the space the chrome is designed in, and
/// converted to linear for the Metal drawable, which renders into an extended
/// *linear* space. Handing the same number to both would make the canvas visibly
/// lighter than the title bar it is meant to be continuous with.
enum Theme {
    static let defaultBackgroundSRGB: CGFloat = 0.26

    static var backgroundSRGB: CGFloat {
        get { Preferences.backgroundLevel }
        set { Preferences.backgroundLevel = min(max(newValue, 0.02), 0.96) }
    }

    static var background: NSColor { grey(backgroundSRGB) }

    static var backgroundLinear: Double {
        let v = Double(backgroundSRGB)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Whether text has to be dark to be read. Only the *polarity* switches here;
    /// the shades themselves ramp continuously on either side of it, so moving the
    /// backdrop looks like a dimmer rather than a series of steps.
    static var isLightBackground: Bool { backgroundSRGB > 0.5 }

    // MARK: - Text

    enum TextRole { case primary, secondary, tertiary }

    /// Text tracks the backdrop continuously within each polarity, pushed hardest
    /// toward the extremes as the backdrop nears mid grey — which is exactly where
    /// contrast is scarcest — and eased off at the ends, where there is plenty and
    /// pure white on near-black would only glare.
    ///
    /// One polarity switch is unavoidable: no continuous path from white to black
    /// avoids passing through mid grey, which against a mid-grey backdrop is
    /// illegible. So the crossover sits at 0.5, where both options are at their
    /// most readable and the change is least visible.
    static func text(_ role: TextRole) -> NSColor {
        let L = backgroundSRGB
        let base: CGFloat = isLightBackground ? (L - 0.5) * 0.5 : 1 - (0.5 - L) * 0.5
        let fade: CGFloat
        switch role {
        case .primary:   fade = 0
        case .secondary: fade = 0.22
        case .tertiary:  fade = 0.36
        }
        return grey(base + (L - base) * fade)
    }

    static var separator: NSColor {
        let L = backgroundSRGB
        return grey(isLightBackground ? max(0, L - 0.12) : min(1, L + 0.12))
    }

    // MARK: - Surfaces

    /// Scope plates follow the backdrop but stay in the lower part of the range.
    ///
    /// They carry light traces, and a plate light enough to match a pale surround
    /// would erase them. Tracking proportionally keeps the panel feeling of a
    /// piece while guaranteeing the scopes stay readable at any setting.
    static var scopeBackground: NSColor {
        grey(min(max(backgroundSRGB * 0.5, 0.03), 0.30))
    }

    /// Slider tracks and other filled control furniture.
    static var controlFill: NSColor {
        let L = backgroundSRGB
        return grey(isLightBackground ? max(0, L - 0.30) : min(1, L + 0.26))
    }

    /// Marks drawn straight onto the backdrop, such as the scrollbar pill.
    static var overlayMark: NSColor { isLightBackground ? .black : .white }

    /// Controls have no continuum in AppKit — a segmented control is either the
    /// light or the dark rendering, never between — so this is the one place a
    /// hard switch remains, and it is confined to control chrome.
    static var appearance: NSAppearance? {
        NSAppearance(named: isLightBackground ? .aqua : .darkAqua)
    }

    private static func grey(_ v: CGFloat) -> NSColor {
        let c = min(max(v, 0), 1)
        return NSColor(srgbRed: c, green: c, blue: c, alpha: 1)
    }

    static let panelWidth: CGFloat = 320

    /// The colour panel's title-bar icon: an "o" — a ring carrying a sweep from
    /// dark to light all the way round, with a seam at the top.
    ///
    /// Drawn per pixel because CoreGraphics has linear and radial gradients but
    /// no angular one, and because doing it by hand gives clean antialiasing on
    /// both edges of the ring at 15pt.
    ///
    /// Active and inactive differ only in brightness — the same mark, lit or
    /// dimmed — rather than being two different glyphs.
    static func gradeIcon(size s: CGFloat = 15, active: Bool) -> NSImage {
        // Never down to true black: on a dark title bar that half of the ring
        // would simply disappear and the "o" would read as a "c".
        let low: CGFloat = active ? 0.34 : 0.16
        let high: CGFloat = active ? 1.0 : 0.46

        let px = Int(s * 2)                        // @2x, then labelled as s points
        let img = NSImage(size: NSSize(width: s, height: s))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: px * 4, bitsPerPixel: 32)
        else { return img }

        guard let buf = rep.bitmapData else { return img }
        let d = CGFloat(px)
        let outerR = d / 2 - 1
        let innerR = outerR * 0.52
        let aa: CGFloat = 1.2

        for y in 0..<px {
            for x in 0..<px {
                let dx = CGFloat(x) + 0.5 - d / 2
                let dy = CGFloat(y) + 0.5 - d / 2
                let r = (dx * dx + dy * dy).squareRoot()

                // Inside the annulus, softened at both edges.
                let outerA = min(max((outerR - r) / aa + 0.5, 0), 1)
                let innerA = min(max((r - innerR) / aa + 0.5, 0), 1)
                let alpha = outerA * innerA
                guard alpha > 0.001 else { continue }

                // A bitmap rep's y runs downward, so negate it to get "up", then
                // measure clockwise from north — putting the seam at the top and
                // running light into dark the way round the reference does.
                var a = atan2(dx, -dy)
                if a < 0 { a += 2 * .pi }
                let v = high - (high - low) * (a / (2 * .pi))

                // Premultiplied, which is what an NSBitmapImageRep expects.
                let g = UInt8(min(max(v, 0), 1) * alpha * 255)
                let o = (y * px + x) * 4
                buf[o] = g; buf[o + 1] = g; buf[o + 2] = g
                buf[o + 3] = UInt8(alpha * 255)
            }
        }
        img.addRepresentation(rep)
        return img
    }
}
