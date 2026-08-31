import AppKit
import simd

/// Right-hand diagnostics panel: histogram, RGB parade, vectorscope, statistics.
final class ScopesPanel: NSView {
    private let histogram = ScopeView(title: "Histogram", heightRatio: 0.42)
    private let parade = ScopeView(title: "RGB Parade", heightRatio: 0.42)
    private let vectorscope = VectorscopeView(title: "Vectorscope", heightRatio: 1)
    private let stats = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "Scopes read sRGB-encoded values.")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor

        let stack = NSStackView(views: [histogram, parade, vectorscope, stats, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stats.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        stats.textColor = .secondaryLabelColor
        stats.lineBreakMode = .byWordWrapping
        stats.maximumNumberOfLines = 0

        note.font = .systemFont(ofSize: 9)
        note.textColor = .tertiaryLabelColor

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),

            histogram.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            parade.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            vectorscope.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            stats.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(with s: Scopes?, image: FloatImage?) {
        histogram.content = s?.histogram
        parade.content = s?.parade
        vectorscope.content = s?.vectorscope
        stats.stringValue = s.map { text(for: $0, image: image) } ?? "No image."
    }

    private func text(for s: Scopes, image: FloatImage?) -> String {
        let st = s.stats
        func triple(_ v: SIMD3<Float>) -> String {
            String(format: "%.4f  %.4f  %.4f", v.x, v.y, v.z)
        }
        let pct = { (n: Int) -> String in
            st.sampleCount == 0 ? "—"
                : String(format: "%.2f%%", Double(n) / Double(st.sampleCount) * 100)
        }
        var lines = [
            "min    \(triple(st.min))",
            "max    \(triple(st.max))",
            "mean   \(triple(st.mean))",
            "",
            "at/over white   \(pct(st.clippedHigh))",
            "at/under black  \(pct(st.clippedLow))",
        ]
        if st.aboveOne > 0 {
            lines.append("above 1.0       \(pct(st.aboveOne))  ▲ HDR")
        }
        if let i = image {
            lines.append("")
            lines.append("sampled \(st.sampleCount) of \(i.width * i.height) px")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Scope views

private class ScopeView: NSView {
    private let label: NSTextField
    private let heightRatio: CGFloat
    var content: CGImage? { didSet { needsDisplay = true } }

    init(title: String, heightRatio: CGFloat) {
        self.heightRatio = heightRatio
        label = NSTextField(labelWithString: title.uppercased())
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            heightAnchor.constraint(equalTo: widthAnchor, multiplier: heightRatio, constant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var plotRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 18))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = plotRect
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        Theme.scopeBackground.setFill()
        path.fill()

        guard let img = content else { return }
        ctx.saveGState()
        path.addClip()
        ctx.interpolationQuality = .high
        ctx.draw(img, in: r)
        ctx.restoreGState()

        NSColor.white.withAlphaComponent(0.06).setStroke()
        path.lineWidth = 1
        path.stroke()
        drawOverlay(in: r, ctx: ctx)
    }

    func drawOverlay(in r: NSRect, ctx: CGContext) {}
}

/// Vectorscope with a graticule derived from the same BT.709 maths as the trace,
/// so the targets can't drift out of agreement with what's plotted.
private final class VectorscopeView: ScopeView {
    private static let targets: [(String, SIMD3<Float>)] = [
        ("R",  [0.75, 0, 0]),    ("Yl", [0.75, 0.75, 0]),
        ("G",  [0, 0.75, 0]),    ("Cy", [0, 0.75, 0.75]),
        ("B",  [0, 0, 0.75]),    ("Mg", [0.75, 0, 0.75]),
    ]

    private func position(of e: SIMD3<Float>, in r: NSRect) -> NSPoint {
        let y = 0.2126 * e.x + 0.7152 * e.y + 0.0722 * e.z
        let cb = (e.z - y) / 1.8556
        let cr = (e.x - y) / 1.5748
        // The raster puts cb across and cr up; the view is y-up, so cr maps directly.
        return NSPoint(x: r.minX + CGFloat(cb + 0.5) * r.width,
                       y: r.minY + CGFloat(cr + 0.5) * r.height)
    }

    override func drawOverlay(in r: NSRect, ctx: CGContext) {
        let side = min(r.width, r.height)
        let square = NSRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)

        NSColor.white.withAlphaComponent(0.13).setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: square.midX, y: square.minY))
        cross.line(to: NSPoint(x: square.midX, y: square.maxY))
        cross.move(to: NSPoint(x: square.minX, y: square.midY))
        cross.line(to: NSPoint(x: square.maxX, y: square.midY))
        cross.lineWidth = 1
        cross.stroke()

        for frac in [0.5, 1.0] {
            let d = side * 0.72 * frac
            let c = NSBezierPath(ovalIn: NSRect(x: square.midX - d / 2, y: square.midY - d / 2,
                                                width: d, height: d))
            c.lineWidth = 1
            NSColor.white.withAlphaComponent(frac == 1 ? 0.13 : 0.08).setStroke()
            c.stroke()
        }

        for (name, rgb) in VectorscopeView.targets {
            let p = position(of: rgb, in: square)
            let box = NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
            NSColor.white.withAlphaComponent(0.5).setStroke()
            let b = NSBezierPath(rect: box)
            b.lineWidth = 1
            b.stroke()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: NSColor.white.withAlphaComponent(0.45),
            ]
            (name as NSString).draw(at: NSPoint(x: p.x + 5, y: p.y - 4), withAttributes: attrs)
        }
    }
}
