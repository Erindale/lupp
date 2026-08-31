import AppKit
import simd

/// Right-hand panel: display controls at the top, scopes in the middle, what the
/// file is and how it's being shown at the bottom.
final class ScopesPanel: NSView {
    var onChannel: ((ChannelView) -> Void)?
    var onClipping: ((Bool) -> Void)?
    var onFalseColour: ((Bool) -> Void)?
    var onViewTransform: ((ViewTransform) -> Void)?
    var onLoadLUT: (() -> Void)?
    var onClearLUT: (() -> Void)?
    var onLUTAmount: ((Float) -> Void)?

    private let channelControl = NSSegmentedControl(
        labels: ChannelView.allCases.map(\.label),
        trackingMode: .selectOne, target: nil, action: nil)
    /// Same segmented treatment as the channel row, but `.selectAny` so the two
    /// overlays are independent toggles rather than a choice of one.
    private let overlayControl = NSSegmentedControl(
        labels: ["Clipping", "False colour"],
        trackingMode: .selectAny, target: nil, action: nil)

    private let histogram = ScopeView(title: "Histogram", heightRatio: 0.42)
    private let cie = CIEView(title: "CIE 1931 xy", heightRatio: 1)
    private let paradeMode = NSSegmentedControl(labels: ["Parade", "Combined", "Luma"],
                                                trackingMode: .selectOne, target: nil, action: nil)
    private lazy var parade = ScopeView(title: "Waveform", heightRatio: 0.42,
                                        accessory: paradeMode)
    private let vectorscope = VectorscopeView(title: "Vectorscope", heightRatio: 1)
    private let stats = NSTextField(labelWithString: "")

    private let lutButtons = NSSegmentedControl(labels: ["Load LUT…", "Clear"],
                                                trackingMode: .momentary, target: nil, action: nil)
    private let lutLabel = NSTextField(labelWithString: "No LUT")
    private let lutSlider = NSSlider(value: 100, minValue: 0, maxValue: 100,
                                     target: nil, action: nil)

    private let transformPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let transformNote = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "Scopes read sRGB-encoded values.")

    /// Held so switching parade mode is instant — both rasters already exist.
    private var current: Scopes?

    /// True while a control's own action is running.
    ///
    /// The action mutates the canvas's display state, which reports back and asks
    /// this panel to re-sync its controls — landing inside AppKit's still-running
    /// click handling and stomping the change the click just made. That made the
    /// overlay toggles impossible to switch off: the deselect was undone before
    /// the mouse came up.
    private var handlingControlAction = false

    private func emit(_ body: () -> Void) {
        handlingControlAction = true
        body()
        handlingControlAction = false
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor

        paradeMode.segmentStyle = .rounded
        paradeMode.controlSize = .mini
        paradeMode.font = .systemFont(ofSize: 9)
        paradeMode.selectedSegment = min(2, max(0, Preferences.paradeMode))
        paradeMode.target = self
        paradeMode.action = #selector(paradeModeChanged(_:))
        // Neutral rather than the system accent: in a scopes panel a saturated
        // highlight reads as a colour cue about the image, not about the control.
        paradeMode.selectedSegmentBezelColor = NSColor(white: 0.42, alpha: 1)

        let channelRow = buildChannelRow()
        overlayControl.segmentDistribution = .fillEqually
        overlayControl.segmentStyle = .rounded
        overlayControl.controlSize = .regular
        overlayControl.font = .systemFont(ofSize: 11)
        overlayControl.target = self
        overlayControl.action = #selector(overlayChanged(_:))
        overlayControl.selectedSegmentBezelColor = NSColor(white: 0.44, alpha: 1)
        overlayControl.translatesAutoresizingMaskIntoConstraints = false

        buildTransformControls()
        buildLUTControls()

        stats.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        stats.textColor = .secondaryLabelColor
        stats.lineBreakMode = .byWordWrapping
        stats.maximumNumberOfLines = 0
        for f in [note, transformNote] {
            f.font = .systemFont(ofSize: 9)
            f.textColor = .tertiaryLabelColor
            f.lineBreakMode = .byWordWrapping
            f.maximumNumberOfLines = 0
        }

        let stack = NSStackView(views: [
            channelRow, overlayControl,
            histogram, parade, vectorscope, cie,
            stats,
            separator(), transformPopup, transformNote,
            lutButtons, lutLabel, lutSlider, note,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(6, after: channelRow)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller = OverlayScroller()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // Flipped: an NSScrollView's document view is bottom-origin by default,
        // which pins short content to the bottom of the panel instead of the top.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        addSubview(scroll)

        var c: [NSLayoutConstraint] = [
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ]
        for v in [channelControl, overlayControl, histogram, parade, vectorscope, cie, stats,
                  transformPopup, transformNote, lutButtons, lutLabel, lutSlider,
                  note] as [NSView] {
            c.append(v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28))
        }
        NSLayoutConstraint.activate(c)

        syncControls()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Controls

    /// One segmented row of equal-width cells, as Blender's image editor does it.
    /// Radio buttons were the literal request but read as a form control and, on
    /// macOS, paint their dot in the system accent — which is the coloured
    /// distraction this panel is meant not to have.
    private func buildChannelRow() -> NSView {
        channelControl.segmentDistribution = .fillEqually
        channelControl.segmentStyle = .rounded
        channelControl.controlSize = .regular
        channelControl.font = .systemFont(ofSize: 11)
        channelControl.selectedSegment = 0
        channelControl.target = self
        channelControl.action = #selector(channelChanged(_:))
        channelControl.selectedSegmentBezelColor = NSColor(white: 0.44, alpha: 1)
        channelControl.translatesAutoresizingMaskIntoConstraints = false
        return channelControl
    }

    /// A creative LUT sits on top of the view transform, so it lives directly
    /// under it — the panel reads top to bottom as the order the pixels travel.
    private func buildLUTControls() {
        lutButtons.segmentDistribution = .fillEqually
        lutButtons.segmentStyle = .rounded
        lutButtons.controlSize = .small
        lutButtons.font = .systemFont(ofSize: 10)
        lutButtons.target = self
        lutButtons.action = #selector(lutButtonPressed(_:))
        lutButtons.translatesAutoresizingMaskIntoConstraints = false

        lutLabel.font = .systemFont(ofSize: 9)
        lutLabel.textColor = .tertiaryLabelColor
        lutLabel.lineBreakMode = .byTruncatingMiddle

        lutSlider.controlSize = .small
        // Neutral fill, like every other control here — the accent colour in a
        // scopes panel reads as information about the image.
        lutSlider.trackFillColor = NSColor(white: 0.52, alpha: 1)
        lutSlider.target = self
        lutSlider.action = #selector(lutAmountChanged(_:))
        lutSlider.isEnabled = false
    }

    @objc private func lutButtonPressed(_ sender: NSSegmentedControl) {
        emit { sender.selectedSegment == 0 ? onLoadLUT?() : onClearLUT?() }
    }

    @objc private func lutAmountChanged(_ sender: NSSlider) {
        emit { onLUTAmount?(Float(sender.doubleValue / 100)) }
    }

    private func buildTransformControls() {
        transformPopup.controlSize = .small
        transformPopup.font = .systemFont(ofSize: 11)
        transformPopup.target = self
        transformPopup.action = #selector(transformChanged(_:))
        for t in ViewTransform.allCases {
            transformPopup.addItem(withTitle: t.label)
            transformPopup.lastItem?.tag = t.rawValue
        }
    }

    private func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    @objc private func channelChanged(_ sender: NSSegmentedControl) {
        guard let ch = ChannelView(rawValue: sender.selectedSegment) else { return }
        emit { onChannel?(ch) }
    }

    @objc private func overlayChanged(_ sender: NSSegmentedControl) {
        emit {
            onClipping?(sender.isSelected(forSegment: 0))
            onFalseColour?(sender.isSelected(forSegment: 1))
        }
    }

    @objc private func transformChanged(_ sender: NSPopUpButton) {
        guard let t = ViewTransform(rawValue: sender.selectedTag()) else { return }
        emit { onViewTransform?(t) }
    }

    @objc private func paradeModeChanged(_ sender: NSSegmentedControl) {
        Preferences.paradeMode = sender.selectedSegment
        applyParadeMode()
    }

    private func syncControls() {
        channelControl.selectedSegment = 0
    }

    /// Reflect the state the canvas is actually in, so the panel can't drift out
    /// of sync with what's on screen after an image loads and re-detects.
    func show(display: Renderer.DisplayState, detected: ViewTransform?, sceneLinear: Bool) {
        // Never write back into a control that is mid-click; only reflect state
        // that changed from somewhere else, such as a keyboard shortcut.
        if !handlingControlAction {
            channelControl.selectedSegment = display.channel.rawValue
            overlayControl.setSelected(display.showClipping, forSegment: 0)
            overlayControl.setSelected(display.falseColour, forSegment: 1)
            transformPopup.selectItem(withTag: display.viewTransform.rawValue)
        }

        if let name = display.lutName {
            lutLabel.stringValue = name
            lutSlider.isEnabled = true
            if !handlingControlAction { lutSlider.doubleValue = Double(display.lutAmount) * 100 }
        } else {
            lutLabel.stringValue = "No LUT"
            lutSlider.isEnabled = false
        }

        if let detected {
            let source = sceneLinear
                ? "Scene-linear file — no view transform is recorded in it, so this is the default for linear sources."
                : "Display-referred file — already graded, so no tone map is applied."
            transformNote.stringValue = display.viewTransform == detected
                ? source
                : "Overriding the detected \(detected.label). \(display.viewTransform.detail)"
        } else {
            transformNote.stringValue = ""
        }
    }

    // MARK: - Scopes

    func update(with s: Scopes?, image: FloatImage?) {
        current = s
        histogram.content = s?.histogram
        cie.content = s?.cie
        vectorscope.content = s?.vectorscope
        applyParadeMode()
        stats.stringValue = s.map { text(for: $0, image: image) } ?? "No image."
    }

    private func applyParadeMode() {
        switch Preferences.paradeMode {
        case 1:  parade.content = current?.paradeCombined; parade.title = "Waveform · combined"
        case 2:  parade.content = current?.waveform;       parade.title = "Waveform · luma"
        default: parade.content = current?.paradeSplit;    parade.title = "Waveform · RGB parade"
        }
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
            lines.append("\(i.sourceColorSpace)")
            lines.append("sampled \(st.sampleCount) of \(i.width * i.height) px")
        }
        return lines.joined(separator: "\n")
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Scope views

private class ScopeView: NSView {
    private let label: NSTextField

    var title: String = "" {
        didSet { label.stringValue = title.uppercased() }
    }
    private let heightRatio: CGFloat
    var content: CGImage? { didSet { needsDisplay = true } }

    init(title: String, heightRatio: CGFloat, accessory: NSView? = nil) {
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

        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor),
                accessory.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            ])
        }
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

        if let img = content {
            ctx.saveGState()
            path.addClip()
            ctx.interpolationQuality = .high
            ctx.draw(img, in: r)
            ctx.restoreGState()
        }

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

        // Skin-tone line: the I axis at roughly 123°, which faces read along
        // regardless of complexion. Resolve draws the same reference.
        let angle = 123.0 * .pi / 180
        let reach = side * 0.42
        let skin = NSBezierPath()
        skin.move(to: NSPoint(x: square.midX, y: square.midY))
        skin.line(to: NSPoint(x: square.midX + cos(angle) * reach,
                              y: square.midY + sin(angle) * reach))
        skin.lineWidth = 1
        NSColor(srgbRed: 1, green: 0.75, blue: 0.65, alpha: 0.42).setStroke()
        skin.stroke()

        for (name, rgb) in VectorscopeView.targets {
            let p = position(of: rgb, in: square)
            NSColor.white.withAlphaComponent(0.5).setStroke()
            let b = NSBezierPath(rect: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            b.lineWidth = 1
            b.stroke()
            (name as NSString).draw(at: NSPoint(x: p.x + 5, y: p.y - 4), withAttributes: [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: NSColor.white.withAlphaComponent(0.45),
            ])
        }
    }
}

/// CIE 1931 xy scope: where the image's colours actually sit, against the
/// spectral locus and the gamuts they might be claiming to use.
private final class CIEView: ScopeView {
    private func point(_ p: CGPoint, in r: NSRect) -> NSPoint {
        NSPoint(x: r.minX + p.x / CIE.xMax * r.width,
                y: r.minY + p.y / CIE.yMax * r.height)
    }

    override func drawOverlay(in r: NSRect, ctx: CGContext) {
        // Spectral locus, closed by the line of purples.
        let locus = NSBezierPath()
        for (i, p) in CIE.spectralLocus.enumerated() {
            let v = point(p, in: r)
            if i == 0 { locus.move(to: v) } else { locus.line(to: v) }
        }
        locus.close()
        locus.lineWidth = 1
        NSColor.white.withAlphaComponent(0.28).setStroke()
        locus.stroke()

        let styles: [(CGFloat, [CGFloat])] = [(0.55, []), (0.42, [3, 2]), (0.34, [1, 2])]
        for (i, g) in CIE.gamuts.enumerated() {
            let tri = NSBezierPath()
            tri.move(to: point(g.red, in: r))
            tri.line(to: point(g.green, in: r))
            tri.line(to: point(g.blue, in: r))
            tri.close()
            tri.lineWidth = 1
            let (alpha, dash) = styles[min(i, styles.count - 1)]
            if !dash.isEmpty { tri.setLineDash(dash, count: dash.count, phase: 0) }
            NSColor.white.withAlphaComponent(alpha).setStroke()
            tri.stroke()

            let label = point(g.green, in: r)
            (g.name as NSString).draw(at: NSPoint(x: label.x + 3, y: label.y - 2),
                                      withAttributes: [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            ])
        }

        let w = point(CIE.d65, in: r)
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: w.x - 3, y: w.y)); cross.line(to: NSPoint(x: w.x + 3, y: w.y))
        cross.move(to: NSPoint(x: w.x, y: w.y - 3)); cross.line(to: NSPoint(x: w.x, y: w.y + 3))
        cross.lineWidth = 1
        cross.stroke()
    }
}
