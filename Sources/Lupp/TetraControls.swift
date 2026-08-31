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
        field.target = self
        field.action = #selector(fieldEdited)

        for v in [name, slider, field] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.widthAnchor.constraint(equalToConstant: 84),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),

            field.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.widthAnchor.constraint(equalToConstant: 52),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        value = initial
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func sliderMoved() {
        field.stringValue = String(format: "%.\(decimals)f", slider.doubleValue)
        onChange?()
    }

    /// Typed values aren't clamped to the slider's range — the slider is a
    /// convenience, not the limit of what the transform accepts.
    @objc private func fieldEdited() {
        guard let v = Double(field.stringValue) else {
            field.stringValue = String(format: "%.\(decimals)f", slider.doubleValue)
            return
        }
        slider.doubleValue = min(max(v, slider.minValue), slider.maxValue)
        field.stringValue = String(format: "%.\(decimals)f", v)
        onChange?()
    }
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
