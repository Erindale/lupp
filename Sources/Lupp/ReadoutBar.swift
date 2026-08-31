import AppKit
import simd

/// The bottom strip: what colour is under the cursor, and how far in we are.
///
/// Painted flat in the window background rather than given a material, so the
/// footer, the canvas and the title bar are one continuous surface with no seam
/// where they meet.
final class ReadoutBar: NSView {
    private let swatch = SwatchView()
    private let left = ReadoutBar.label(alignment: .left)
    private let right = ReadoutBar.label(alignment: .right)

    static let height: CGFloat = 26

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor

        for v in [swatch, left, right] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 13),
            swatch.heightAnchor.constraint(equalToConstant: 13),

            left.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 8),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),

            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func label(alignment: NSTextAlignment) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        f.textColor = .secondaryLabelColor
        f.alignment = alignment
        f.lineBreakMode = .byTruncatingMiddle
        return f
    }

    func update(pixel: (x: Int, y: Int)?, value: SIMD4<Float>?,
                zoomPercent: Double, exposureEV: Float, downsampled: Bool) {
        if let p = pixel, let v = value {
            let hex = String(format: "#%02X%02X%02X",
                             Int((linearToSRGB(v.x) * 255).rounded()),
                             Int((linearToSRGB(v.y) * 255).rounded()),
                             Int((linearToSRGB(v.z) * 255).rounded()))
            var s = String(format: "%d, %d    %.4f  %.4f  %.4f    sRGB %@",
                           p.x, p.y, v.x, v.y, v.z, hex)
            if v.w < 0.999 { s += String(format: "    A %.3f", v.w) }
            if max(v.x, max(v.y, v.z)) > 1.0001 { s += "    ▲ HDR" }
            left.stringValue = s
            swatch.color = NSColor(red: CGFloat(linearToSRGB(v.x)),
                                   green: CGFloat(linearToSRGB(v.y)),
                                   blue: CGFloat(linearToSRGB(v.z)), alpha: 1)
        } else {
            left.stringValue = "—"
            swatch.color = nil
        }

        var r = String(format: "%.0f%%", zoomPercent)
        if exposureEV != 0 { r += String(format: "    EV %+.2f", exposureEV) }
        if downsampled { r += "    reduced" }
        right.stringValue = r
    }
}

private final class SwatchView: NSView {
    var color: NSColor? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 2.5, yRadius: 2.5)
        (color ?? NSColor.clear).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
