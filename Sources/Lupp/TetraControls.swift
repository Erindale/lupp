import AppKit
import simd

/// One labelled slider with a typed value beside it, as Resolve presents a
/// DCTL's parameters.
///
/// Used for every numeric grade control, not just the tetra corners, because the
/// useful motion in all of them is a nudge along one axis — "a little less blue
/// in the reds", "a third of a stop down" — and the value needs to be readable
/// and typeable while you do it.
class LabelledSliderRow: NSView {
    private let slider = FineSlider()
    private let field = NSTextField()
    var onChange: (() -> Void)?
    /// Passed through to the slider so one drag is one undoable edit. The typed
    /// field is a single change already, so it brackets itself.
    var onEditBegan: (() -> Void)? {
        get { slider.onEditBegan } set { slider.onEditBegan = newValue }
    }
    var onEditEnded: (() -> Void)? {
        get { slider.onEditEnded } set { slider.onEditEnded = newValue }
    }

    /// Default span for the tetra corners.
    static let span: Double = 1.0

    private let defaultValue: Float

    private let decimals: Int

    var value: Float {
        get { Float(slider.doubleValue) }
        set {
            slider.doubleValue = Double(newValue)
            field.stringValue = String(format: "%.\(decimals)f", newValue)
        }
    }

    func resetToDefault() { value = defaultValue }

    /// The slider is centred on the parameter's *identity* value rather than
    /// every row sharing one absolute range, so a handle at the middle always
    /// means "unchanged" and its distance from the middle reads directly as
    /// deviation. It answers "how far have I moved this", which is the question
    /// you actually have while grading.
    init(label: String, initial: Float, span: Double = LabelledSliderRow.span,
         decimals: Int = 3) {
        self.defaultValue = initial
        self.decimals = decimals
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let name = ThemedLabel(label, role: .secondary, size: 10)
        name.alignment = .right
        name.lineBreakMode = .byTruncatingTail

        slider.minValue = Double(initial) - span
        slider.maxValue = Double(initial) + span
        slider.controlSize = .small
        slider.trackFillColor = Theme.controlFill
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.isContinuous = true

        field.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        field.alignment = .right
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        // No target/action: a text field sends its action whenever editing ends,
        // which would commit a half-typed number just because you clicked away.
        // Return is the only thing that should commit, so Return is handled
        // explicitly and everything else discards.
        field.delegate = self

        for v in [name, slider, field] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.scaled(20)),
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.widthAnchor.constraint(equalToConstant: Theme.scaled(84)),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),

            field.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.widthAnchor.constraint(equalToConstant: Theme.scaled(52)),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        value = initial
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func sliderMoved() {
        displayCurrentValue()
        onChange?()
    }

    private func displayCurrentValue() {
        field.stringValue = String(format: "%.\(decimals)f", slider.doubleValue)
    }

    /// Take what was typed, if it is a number at all.
    ///
    /// Anything else is left alone rather than argued with — no alert, no beep.
    /// The end-editing pass puts the real value back, so a typo simply undoes
    /// itself, which is what you want from a field you are nudging by eye.
    private func commitTypedValue() {
        guard let v = Double(field.stringValue) else { return }
        slider.doubleValue = min(max(v, slider.minValue), slider.maxValue)
        onChange?()
    }

    /// Hand the keyboard back to the picture, so the bare-key shortcuts work
    /// again the moment you have finished typing.
    private func releaseKeyboard() {
        guard let window else { return }
        window.makeFirstResponder(window.initialFirstResponder)
    }
}

extension LabelledSliderRow: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitTypedValue()
            releaseKeyboard()
            return true
        // Escape reaches a field editor as `cancelOperation:` on some paths and
        // as `complete:` on others, since the text system treats it as "abandon
        // the completion you were offered" first. Neither means anything else
        // in a box that only holds a number, so both simply back out.
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            displayCurrentValue()   // put the real value back before anyone sees it
            releaseKeyboard()
            return true
        default:
            return false
        }
    }

    /// However the edit ended, the field goes back to showing the value that is
    /// actually in effect. Return has already committed by the time this runs,
    /// so this is what discards anything typed and not committed — including
    /// text that was never a number.
    func controlTextDidEndEditing(_ obj: Notification) {
        displayCurrentValue()
    }

    /// Nothing here formats on the way in, but if that ever changes, a value
    /// the formatter cannot read must not be allowed to refuse to give up the
    /// keyboard. Accepting it here means the revert above still gets to run.
    func control(_ control: NSControl, didFailToFormatString string: String,
                 errorDescription error: String?) -> Bool { true }
}

/// A tetra corner's slider, carrying which parameter it drives.
final class TetraSliderRow: LabelledSliderRow {
    let corner: Int          // 0…5 in R G B C M Y order
    let component: Int       // 0 R, 1 G, 2 B

    init(label: String, corner: Int, component: Int, initial: Float) {
        self.corner = corner
        self.component = component
        super.init(label: label, initial: initial)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The eighteen parameters, in the order Resolve lists them.
enum TetraLayout {
    /// Corner index → the TetraCorners member it drives.
    static let cornerNames = ["Red", "Green", "Blue", "Cyan", "Magenta", "Yellow"]
    static let componentNames = ["Red", "Green", "Blue"]

    /// Identity: each corner sits at its own primary or secondary.
    static let identity: [[Float]] = [
        [1, 0, 0],   // Red
        [0, 1, 0],   // Green
        [0, 0, 1],   // Blue
        [0, 1, 1],   // Cyan
        [1, 0, 1],   // Magenta
        [1, 1, 0],   // Yellow
    ]

    static func corners(from v: [[Float]]) -> Renderer.TetraCorners {
        var t = Renderer.TetraCorners()
        func c(_ i: Int) -> SIMD4<Float> { SIMD4(v[i][0], v[i][1], v[i][2], 0) }
        t.red = c(0); t.green = c(1); t.blue = c(2)
        t.cyan = c(3); t.magenta = c(4); t.yellow = c(5)
        return t
    }

    static func values(from t: Renderer.TetraCorners) -> [[Float]] {
        [t.red, t.green, t.blue, t.cyan, t.magenta, t.yellow].map { [$0.x, $0.y, $0.z] }
    }
}
