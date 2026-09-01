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
    /// For a file that is wrong about which way up it is. Both directions,
    /// because one button means three clicks to go the other way.
    private let rotateLeft = ReadoutBar.rotateButton(
        clockwise: false, tip: "Rotate anticlockwise",
        action: #selector(ViewerWindowController.rotateImageLeft(_:)))
    private let rotateRight = ReadoutBar.rotateButton(
        clockwise: true, tip: "Rotate clockwise",
        action: #selector(ViewerWindowController.rotateImageRight(_:)))

    static var height: CGFloat { Theme.scaled(26) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor

        for v in [swatch, left, rotateLeft, rotateRight, right] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.scaled(10)),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: Theme.scaled(13)),
            swatch.heightAnchor.constraint(equalToConstant: Theme.scaled(13)),

            left.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: Theme.scaled(8)),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),

            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.scaled(10)),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Sized explicitly: an 11pt glyph is a smaller target than anyone can
            // reliably hit, and the footer has the room.
            rotateRight.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -Theme.scaled(8)),
            rotateRight.centerYAnchor.constraint(equalTo: centerYAnchor),
            rotateRight.widthAnchor.constraint(equalToConstant: Theme.scaled(22)),
            rotateRight.heightAnchor.constraint(equalToConstant: Theme.scaled(20)),
            rotateLeft.trailingAnchor.constraint(equalTo: rotateRight.leadingAnchor, constant: 0),
            rotateLeft.centerYAnchor.constraint(equalTo: centerYAnchor),
            rotateLeft.widthAnchor.constraint(equalToConstant: Theme.scaled(22)),
            rotateLeft.heightAnchor.constraint(equalToConstant: Theme.scaled(20)),

            left.trailingAnchor.constraint(lessThanOrEqualTo: rotateLeft.leadingAnchor, constant: -Theme.scaled(12)),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func refreshBackground() {
        layer?.backgroundColor = Theme.background.cgColor
        ThemeRefresh.apply(to: self)
        for b in [rotateLeft, rotateRight] { b.contentTintColor = Theme.text(.tertiary) }
    }

    /// Target stays nil so the action travels the responder chain to whichever
    /// window is in front, the same way the title bar's panel buttons do.
    private static func rotateButton(clockwise: Bool, tip: String,
                                     action: Selector) -> NSButton {
        let b = NSButton()
        b.image = Theme.rotateIcon(size: Theme.scaled(13), clockwise: clockwise)
        b.setAccessibilityLabel(tip)
        b.toolTip = tip
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = Theme.text(.tertiary)
        b.action = action
        return b
    }

    private static func label(alignment: NSTextAlignment) -> NSTextField {
        let f = ThemedLabel("", role: .secondary, size: 11, monospaced: true)
        f.alignment = alignment
        f.lineBreakMode = .byTruncatingMiddle
        return f
    }

    func update(pixel: (x: Int, y: Int)?, value: SIMD4<Float>?,
                sourceValue: SIMD4<Float>? = nil,
                zoomPercent: Double, exposureEV: Float, downsampled: Bool,
                backdrop: CGFloat? = nil) {
        if let backdrop {
            // While the backdrop is being dragged it takes over the readout, so
            // the gesture isn't blind.
            left.stringValue = String(format: "backdrop  %.0f%%", backdrop * 100)
            swatch.color = Theme.background
            right.stringValue = String(format: "%.0f%%", zoomPercent)
            return
        }
        if let p = pixel, let v = value {
            // Already display-encoded by the shader, so these are the numbers on
            // the screen and the hex is the same value written another way.
            let hex = String(format: "#%02X%02X%02X",
                             Int((min(max(v.x, 0), 1) * 255).rounded()),
                             Int((min(max(v.y, 0), 1) * 255).rounded()),
                             Int((min(max(v.z, 0), 1) * 255).rounded()))
            var s = String(format: "%d, %d    %.4f  %.4f  %.4f    %@",
                           p.x, p.y, v.x, v.y, v.z, hex)
            if v.w < 0.999 { s += String(format: "    A %.3f", v.w) }
            // From the file, not the render: the render is clamped to the screen,
            // so it cannot tell you the pixel was brighter than white underneath.
            if let src = sourceValue, max(src.x, max(src.y, src.z)) > 1.0001 {
                s += "    ▲ HDR"
            }
            left.stringValue = s
            swatch.color = NSColor(red: CGFloat(min(max(v.x, 0), 1)),
                                   green: CGFloat(min(max(v.y, 0), 1)),
                                   blue: CGFloat(min(max(v.z, 0), 1)), alpha: 1)
        } else {
            left.stringValue = "—"
            swatch.color = nil
        }

        var r = zoomPercent > 0 ? String(format: "%.0f%%", zoomPercent) : ""
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
        Theme.separator.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
