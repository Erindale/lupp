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

    /// The grade panel's title-bar icon: an "o" — a ring filled with a radial
    /// gradient, echoing the app icon rather than borrowing a system glyph.
    static func gradeIcon(size s: CGFloat = 15) -> NSImage {
        NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let c = CGPoint(x: s / 2, y: s / 2)
            let outer = CGRect(x: 0.5, y: 0.5, width: s - 1, height: s - 1)
            let t = s * 0.30                       // ring thickness
            let inner = outer.insetBy(dx: t, dy: t)

            let ring = CGMutablePath()
            ring.addEllipse(in: outer)
            ring.addEllipse(in: inner)
            ctx.addPath(ring)
            ctx.clip(using: .evenOdd)

            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let colours = [
                CGColor(red: 0.42, green: 0.84, blue: 0.88, alpha: 1),
                CGColor(red: 0.55, green: 0.35, blue: 0.90, alpha: 1),
                CGColor(red: 1.00, green: 0.68, blue: 0.28, alpha: 1),
            ] as CFArray
            if let g = CGGradient(colorsSpace: space, colors: colours,
                                  locations: [0, 0.55, 1]) {
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0,
                                       endCenter: c, endRadius: s / 2,
                                       options: [.drawsAfterEndLocation])
            }
            return true
        }
    }
}
