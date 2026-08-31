import AppKit

/// Shared scaffolding for the side panels.
///
/// Both panels are the same object underneath — a scrolling column of controls
/// in the window background — so the parts that make that work live once here
/// rather than being kept in step by hand in two places.
class SidePanel: NSView {
    /// True while a control's own action is running.
    ///
    /// The action mutates display state, which reports back and asks the panel to
    /// re-sync its controls — landing inside AppKit's still-running click handling
    /// and stomping the change the click just made. That made toggles impossible
    /// to switch off: the deselect was undone before the mouse came up.
    private(set) var handlingControlAction = false

    func emit(_ body: () -> Void) {
        handlingControlAction = true
        body()
        handlingControlAction = false
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Wraps a column of views in a scroll view with Flöt-style overlay bars, and
    /// pins every child to the column width.
    func install(column views: [NSView], fullWidth: [NSView]) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        // Nothing in a panel is ever wider than the panel, so sideways motion can
        // only ever be an accident — a trackpad swipe with a little drift in it.
        // The flags alone are not enough: the document view can still end up a
        // scroller's width wider than the clip view and drift by exactly that, so
        // the clip view pins its own origin.
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.contentView = VerticalOnlyClipView()
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

            // Against the clip view, not the scroll view: they differ by the
            // scroller's width unless overlay scrollers are in play everywhere.
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ]
        for v in fullWidth {
            c.append(v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28))
        }
        NSLayoutConstraint.activate(c)
    }

    // MARK: - Control styling

    func sectionLabel(_ t: String) -> NSTextField {
        let f = NSTextField(labelWithString: t.uppercased())
        f.font = .systemFont(ofSize: 9, weight: .semibold)
        f.textColor = .tertiaryLabelColor
        return f
    }

    func caption(_ t: String = "") -> NSTextField {
        let f = NSTextField(labelWithString: t)
        f.font = .systemFont(ofSize: 9)
        f.textColor = .tertiaryLabelColor
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 0
        return f
    }

    /// Neutral selection rather than the system accent: in a panel about colour,
    /// a saturated highlight reads as information about the image.
    func style(_ c: NSSegmentedControl, size: NSControl.ControlSize = .regular,
               font: CGFloat = 11) {
        c.segmentDistribution = .fillEqually
        c.segmentStyle = .rounded
        c.controlSize = size
        c.font = .systemFont(ofSize: font)
        c.selectedSegmentBezelColor = NSColor(white: 0.44, alpha: 1)
        c.translatesAutoresizingMaskIntoConstraints = false
    }

    func style(_ p: NSPopUpButton) {
        p.controlSize = .small
        p.font = .systemFont(ofSize: 11)
    }

    func style(_ s: NSSlider) {
        s.controlSize = .small
        s.trackFillColor = NSColor(white: 0.52, alpha: 1)
    }

    func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A clip view that refuses to move sideways, whatever it is asked.
final class VerticalOnlyClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        r.origin.x = 0
        return r
    }
}
