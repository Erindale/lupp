import AppKit
import Foundation

/// One background colour for the entire window.
///
/// Authored in sRGB, because that is the space the chrome is designed in, and
/// converted to linear for the Metal drawable — which renders into an extended
/// *linear* space. Handing the same number to both would make the canvas
/// visibly lighter than the title bar it is meant to be continuous with.
enum Theme {
    static let defaultBackgroundSRGB: CGFloat = 0.26

    /// Adjustable, because the right backdrop depends on the image: a bright
    /// surround makes a dark frame look washed out, and vice versa. Right-drag on
    /// the canvas changes it.
    static var backgroundSRGB: CGFloat {
        get { Preferences.backgroundLevel }
        set { Preferences.backgroundLevel = min(max(newValue, 0.02), 0.92) }
    }

    /// Past this the backdrop is light enough that white text stops being
    /// readable on it, so the whole window flips to the light appearance and
    /// AppKit's semantic colours invert with it — labels, controls and all.
    static var isLightBackground: Bool { backgroundSRGB > 0.5 }

    static var appearance: NSAppearance? {
        NSAppearance(named: isLightBackground ? .aqua : .darkAqua)
    }

    /// Scope plates stay dark whatever the surround, as they do in every grading
    /// tool — the traces are drawn light, and a plot that inverted with the chrome
    /// would make them vanish.
    static var scopeTrackTint: NSColor {
        NSColor(white: isLightBackground ? 0.3 : 0.72, alpha: 1)
    }

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
