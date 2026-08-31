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

    /// Asked to re-read the state once a click has finished.
    var onResync: (() -> Void)?

    /// Suppressing the sync during the action is only half the answer: the other
    /// half is doing it afterwards. Without this, anything the action changed
    /// *elsewhere* in the panel — a LUT's name, whether its slider is live, which
    /// entry the popup shows — was simply never picked up, because the only sync
    /// that would have caught it was the one being suppressed.
    func emit(_ body: () -> Void) {
        handlingControlAction = true
        body()
        handlingControlAction = false
        DispatchQueue.main.async { [weak self] in self?.onResync?() }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Repaint after the backdrop changes. The layer colour is not enough: the
    /// scope views draw their own plates and every label re-derives its colour.
    func refreshBackground() {
        layer?.backgroundColor = Theme.background.cgColor
        ThemeRefresh.apply(to: self)
    }

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
        let clip = VerticalOnlyClipView()
        // A fresh clip view arrives with drawsBackground on and its own semantic
        // colour, which paints straight over the panel — and being semantic it
        // only knows light and dark, which is exactly the "either light or dark"
        // slab that refused to follow the backdrop.
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.drawsBackground = false
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

    /// A section title with an optional A/B toggle at the left and a reset at the
    /// right.
    ///
    /// Per section rather than one blanket control, because comparing one change
    /// at a time is the whole point — and undoing a white balance experiment
    /// shouldn't cost you the cube warp you were happy with.
    func sectionHeader(_ t: String, toggle: ((Bool) -> Void)? = nil,
                       reset: @escaping () -> Void) -> SectionHeader {
        SectionHeader(title: t.uppercased(), toggle: toggle, reset: reset)
    }

    private func unusedSectionHeader(_ t: String, reset: @escaping () -> Void) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = sectionLabel(t)
        let button = ActionButton(action: reset)
        button.image = NSImage(systemSymbolName: "arrow.counterclockwise",
                               accessibilityDescription: "Reset \(t)")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .texturedRounded
        button.contentTintColor = Theme.text(.tertiary)
        button.toolTip = "Reset \(t.lowercased()) to defaults"

        for v in [label, button] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 16),
            button.heightAnchor.constraint(equalToConstant: 14),
        ])
        return row
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
        c.selectedSegmentBezelColor = Theme.controlFill
        c.translatesAutoresizingMaskIntoConstraints = false
    }

    func style(_ p: NSPopUpButton) {
        p.controlSize = .small
        p.font = .systemFont(ofSize: 11)
    }

    func style(_ s: NSSlider) {
        s.controlSize = .small
        s.trackFillColor = Theme.controlFill
    }

    func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }
}

/// A section title row: an optional A/B checkbox, the title, and a reset arrow.
final class SectionHeader: NSView {
    private let check: NSButton?
    private let label: ThemedLabel

    var isOn: Bool {
        get { check?.state == .on }
        set { check?.state = newValue ? .on : .off }
    }

    init(title: String, toggle: ((Bool) -> Void)?, reset: @escaping () -> Void) {
        label = ThemedLabel(title, role: .tertiary, size: 9, weight: .semibold)
        if let toggle {
            let b = ActionButton(action: {})
            b.setButtonType(.switch)
            b.title = ""
            b.controlSize = .small
            check = b
        } else {
            check = nil
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        if let check, let toggle {
            // Re-target now that self exists, so the closure can read the state.
            check.target = self
            check.action = #selector(toggled)
            self.toggleHandler = toggle
        }

        let resetButton = ActionButton(action: reset)
        resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise",
                                    accessibilityDescription: "Reset \(title)")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        resetButton.imagePosition = .imageOnly
        resetButton.isBordered = false
        resetButton.bezelStyle = .texturedRounded
        resetButton.contentTintColor = Theme.text(.tertiary)
        resetButton.toolTip = "Reset \(title.lowercased()) to defaults"

        var views: [NSView] = []
        if let check { views.append(check) }
        views.append(contentsOf: [label, resetButton])
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        var c: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            resetButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            resetButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            resetButton.widthAnchor.constraint(equalToConstant: 16),
            resetButton.heightAnchor.constraint(equalToConstant: 14),
        ]
        if let check {
            check.state = .on
            check.toolTip = "Bypass \(title.lowercased()) — compare with and without"
            c += [
                check.leadingAnchor.constraint(equalTo: leadingAnchor),
                check.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 2),
            ]
        } else {
            c.append(label.leadingAnchor.constraint(equalTo: leadingAnchor))
        }
        NSLayoutConstraint.activate(c)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var toggleHandler: ((Bool) -> Void)?

    @objc private func toggled() { toggleHandler?(isOn) }
}

/// An NSButton that carries its own closure, so callers don't each need a
/// selector and a stored property to hang it on.
final class ActionButton: NSButton {
    private let handler: () -> Void

    init(action: @escaping () -> Void) {
        self.handler = action
        super.init(frame: .zero)
        title = ""
        target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// A label that remembers which text role it plays, so the backdrop can be
/// changed at any time and every piece of text re-derives its own colour.
///
/// Explicit roles rather than AppKit's semantic colours, because those only know
/// about light and dark mode — they cannot follow a backdrop that moves
/// continuously.
final class ThemedLabel: NSTextField {
    let role: Theme.TextRole

    init(_ text: String, role: Theme.TextRole, size: CGFloat, weight: NSFont.Weight = .regular,
         monospaced: Bool = false) {
        self.role = role
        super.init(frame: .zero)
        stringValue = text
        font = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight)
                          : .systemFont(ofSize: size, weight: weight)
        isEditable = false
        isBordered = false
        isSelectable = false
        drawsBackground = false
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func applyTheme() { textColor = Theme.text(role) }
}

/// Re-derives every themed colour under a view. One walk rather than each panel
/// keeping its own list, so a control added later cannot be forgotten.
enum ThemeRefresh {
    static func apply(to view: NSView) {
        if let l = view as? ThemedLabel { l.applyTheme() }
        if let s = view as? NSSlider { s.trackFillColor = Theme.controlFill }
        if let c = view as? NSSegmentedControl { c.selectedSegmentBezelColor = Theme.controlFill }
        if let b = view as? NSBox, b.boxType == .separator { b.borderColor = Theme.separator }
        if let b = view as? ActionButton { b.contentTintColor = Theme.text(.tertiary) }
        view.needsDisplay = true
        for sub in view.subviews { apply(to: sub) }
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
