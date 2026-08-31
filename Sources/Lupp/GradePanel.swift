import AppKit
import simd

/// The colour panel: LUT, tetrahedral grade, presets and export.
///
/// Separate from the inspector because the two answer different questions —
/// this one changes the pixels, the inspector only reports on them — and because
/// wanting to grade is not the same as wanting to watch scopes while you do it.
final class GradePanel: SidePanel {
    /// Which part of the chain a bypass switch belongs to.
    enum Section { case master, light, whiteBalance, tetra, lut }

    var onLoadLUT: (() -> Void)?
    var onClearLUT: (() -> Void)?
    var onLUTAmount: ((Float) -> Void)?
    var onPickLUT: ((String?) -> Void)?
    var onRemoveLUT: ((String) -> Void)?
    var onTetra: ((Renderer.TetraCorners, Float, Bool) -> Void)?
    /// exposure EV, white balance gains, contrast, pivot, black point, white point
    var onLight: ((Float, SIMD3<Float>, Float, Float, Float, Float) -> Void)?
    var onSavePreset: (() -> Void)?
    var onUsePreset: ((String) -> Void)?
    var onDeletePreset: ((String) -> Void)?
    var onApplyLast: (() -> Void)?
    var onExport: (() -> Void)?
    var onBypass: ((Section, Bool) -> Void)?

    private let lutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let lutButtons = NSSegmentedControl(labels: ["Add…", "Remove", "Off"],
                                                trackingMode: .momentary, target: nil, action: nil)
    private let lutLabel = ThemedLabel("No LUT", role: .tertiary, size: 9)
    private let lutSlider = NSSlider(value: 100, minValue: 0, maxValue: 100,
                                     target: nil, action: nil)

    private lazy var blackRow = LabelledSliderRow(label: "Black point", initial: 0, span: 0.4)
    private lazy var whiteRow = LabelledSliderRow(label: "White point", initial: 1, span: 0.6)
    private lazy var exposureRow = LabelledSliderRow(label: "Exposure", initial: 0,
                                                    span: 5, decimals: 2)
    private lazy var contrastRow = LabelledSliderRow(label: "Contrast", initial: 1, span: 0.9)
    private lazy var pivotRow = LabelledSliderRow(label: "Pivot", initial: 0.18, span: 0.17)
    private lazy var wbRows = [
        LabelledSliderRow(label: "Red", initial: 1, span: 0.5),
        LabelledSliderRow(label: "Green", initial: 1, span: 0.5),
        LabelledSliderRow(label: "Blue", initial: 1, span: 0.5),
    ]
    private var tetraRows: [TetraSliderRow] = []
    private let tetraAmount = NSSlider(value: 100, minValue: 0, maxValue: 100,
                                       target: nil, action: nil)
    private let savePresetButton = NSButton(title: "Save Preset…", target: nil, action: nil)

    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let presetButtons = NSSegmentedControl(labels: ["Use", "Delete", "Apply Last"],
                                                   trackingMode: .momentary, target: nil, action: nil)

    private let exportButton = NSButton(title: "Export as Displayed…",
                                        target: nil, action: nil)

    private let masterToggle = NSButton()
    private var lightHeader: SectionHeader!
    private var wbHeader: SectionHeader!
    private var tetraHeader: SectionHeader!
    private var lutHeader: SectionHeader!

    override init() {
        super.init()

        style(lutPopup)
        lutPopup.target = self
        lutPopup.action = #selector(lutPicked(_:))
        style(lutButtons, size: .small, font: 10)
        lutButtons.target = self
        lutButtons.action = #selector(lutButtonPressed(_:))
        style(lutSlider)
        lutSlider.target = self
        lutSlider.action = #selector(lutAmountChanged(_:))
        lutSlider.isEnabled = false
        lutLabel.lineBreakMode = .byTruncatingMiddle

        let lightRows = [blackRow, whiteRow, exposureRow, contrastRow, pivotRow]
        let balanceRows = wbRows
        for r in lightRows + balanceRows {
            r.onChange = { [weak self] in self?.lightChanged() }
        }
        let tetraRowViews = buildTetraRows()
        style(tetraAmount)
        tetraAmount.target = self
        tetraAmount.action = #selector(tetraChanged(_:))
        savePresetButton.bezelStyle = .rounded
        savePresetButton.controlSize = .small
        savePresetButton.font = .systemFont(ofSize: 11)
        savePresetButton.target = self
        savePresetButton.action = #selector(savePresetPressed(_:))
        savePresetButton.translatesAutoresizingMaskIntoConstraints = false

        style(presetPopup)
        style(presetButtons, size: .small, font: 10)
        presetButtons.target = self
        presetButtons.action = #selector(presetButtonPressed(_:))

        exportButton.bezelStyle = .rounded
        exportButton.controlSize = .regular
        exportButton.font = .systemFont(ofSize: 11)
        exportButton.target = self
        exportButton.action = #selector(exportPressed(_:))
        exportButton.translatesAutoresizingMaskIntoConstraints = false

        let tetraNote = caption("Moves the six hue corners of the RGB cube. Black, white and the greys between them are fixed, so neutrals stay neutral.")
        let lutNote = caption("Applied after the view transform, in display space. A LUT authored for log input won’t be right here.")
        let exportNote = caption("Writes the image as shown — transform, LUT, grade and exposure baked in, at full resolution.")

        let lightNote = caption("Linear, before the view transform — these behave like light, not like edits to a finished picture. Black and white point set what counts as black and white first; contrast pivots on 0.18 scene grey.")

        lightHeader = sectionHeader("Light",
                                    toggle: { [weak self] on in
                                        self?.emit { self?.onBypass?(.light, on) } },
                                    reset: { [weak self] in self?.resetLight() })
        wbHeader = sectionHeader("White balance",
                                 toggle: { [weak self] on in
                                     self?.emit { self?.onBypass?(.whiteBalance, on) } },
                                 reset: { [weak self] in self?.resetWhiteBalance() })
        tetraHeader = sectionHeader("Grade — tetrahedral",
                                    toggle: { [weak self] on in
                                        self?.emit { self?.onBypass?(.tetra, on) } },
                                    reset: { [weak self] in self?.resetTetra() })
        lutHeader = sectionHeader("LUT",
                                  toggle: { [weak self] on in
                                      self?.emit { self?.onBypass?(.lut, on) } },
                                  reset: { [weak self] in self?.emit { self?.onClearLUT?() } })

        masterToggle.setButtonType(.switch)
        masterToggle.title = "  Grading enabled   (B)"
        masterToggle.font = .systemFont(ofSize: 11)
        masterToggle.state = .on
        masterToggle.target = self
        masterToggle.action = #selector(masterToggled)
        masterToggle.translatesAutoresizingMaskIntoConstraints = false

        var column: [NSView] = [
            masterToggle,
            caption("Every switch below bypasses its section without discarding it — toggling back returns exactly where you were."),
            separator(),
            lightHeader, blackRow, whiteRow, exposureRow, contrastRow, pivotRow,
            wbHeader, wbRows[0], wbRows[1], wbRows[2],
            lightNote,
            separator(),
            tetraHeader,
        ]
        column += tetraRowViews
        column += [caption("Mix"), tetraAmount, tetraNote]

        // Order down the panel is the order the pixels travel: light, then the
        // cube warp, then the LUT on top, then what to do with the result.
        column += [separator(),
                   lutHeader, lutPopup, lutButtons, lutLabel, lutSlider, lutNote,
                   separator(),
                   sectionLabel("Presets"), presetPopup, presetButtons, savePresetButton,
                   separator(),
                   sectionLabel("Export"), exportButton, exportNote]

        install(column: column,
                fullWidth: [lutPopup, lutButtons, lutLabel, lutSlider, lutNote,
                            tetraAmount, tetraNote, lightNote, savePresetButton,
                            presetPopup, presetButtons, exportButton, exportNote,
                            lightHeader, wbHeader, tetraHeader, lutHeader, masterToggle]
                        + tetraRowViews + lightRows + balanceRows)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Tetra

    /// Eighteen labelled sliders, in the order Resolve lists them. Black, white
    /// and the grey axis have no controls because the transform fixes them by
    /// construction — there is nothing there to move.
    private func buildTetraRows() -> [NSView] {
        var views: [NSView] = []
        for (ci, cname) in TetraLayout.cornerNames.enumerated() {
            for (pi, pname) in TetraLayout.componentNames.enumerated() {
                let row = TetraSliderRow(label: "\(cname) \(pname)", corner: ci,
                                         component: pi,
                                         initial: TetraLayout.identity[ci][pi])
                row.onChange = { [weak self] in self?.tetraChanged(nil) }
                tetraRows.append(row)
                views.append(row)
            }
        }
        return views
    }

    private func currentValues() -> [[Float]] {
        var v = TetraLayout.identity
        for row in tetraRows { v[row.corner][row.component] = row.value }
        return v
    }

    private func lightChanged() {
        emit {
            onLight?(exposureRow.value,
                     SIMD3(wbRows[0].value, wbRows[1].value, wbRows[2].value),
                     contrastRow.value, pivotRow.value,
                     blackRow.value, whiteRow.value)
        }
    }

    @objc private func tetraChanged(_ sender: Any?) {
        let corners = TetraLayout.corners(from: currentValues())
        let amount = Float(tetraAmount.doubleValue / 100)
        // Identity corners mean there is nothing to apply, so don't pay for it.
        emit { onTetra?(corners, amount, !corners.isIdentity) }
    }

    @objc private func masterToggled() {
        emit { onBypass?(.master, masterToggle.state == .on) }
    }

    @objc private func savePresetPressed(_ sender: Any?) {
        emit { onSavePreset?() }
    }

    private var lightAndBalanceRows: [LabelledSliderRow] {
        [blackRow, whiteRow, exposureRow, contrastRow, pivotRow] + wbRows
    }

    private func resetLight() {
        for row in [blackRow, whiteRow, exposureRow, contrastRow, pivotRow] {
            row.resetToDefault()
        }
        lightChanged()
    }

    private func resetWhiteBalance() {
        for row in wbRows { row.resetToDefault() }
        lightChanged()
    }

    private func resetTetra() {
        for row in tetraRows { row.resetToDefault() }
        tetraAmount.doubleValue = 100
        tetraChanged(nil)
    }

    // MARK: - LUT and presets

    @objc private func lutPicked(_ sender: NSPopUpButton) {
        let path = sender.selectedItem?.representedObject as? String
        emit { onPickLUT?(sender.indexOfSelectedItem > 0 ? path : nil) }
    }

    @objc private func lutButtonPressed(_ sender: NSSegmentedControl) {
        emit {
            switch sender.selectedSegment {
            case 0: onLoadLUT?()
            case 1:
                if let path = lutPopup.selectedItem?.representedObject as? String {
                    onRemoveLUT?(path)
                }
            default: onClearLUT?()
            }
        }
    }

    @objc private func lutAmountChanged(_ sender: NSSlider) {
        emit { onLUTAmount?(Float(sender.doubleValue / 100)) }
    }

    @objc private func presetButtonPressed(_ sender: NSSegmentedControl) {
        let name = presetPopup.titleOfSelectedItem ?? ""
        emit {
            switch sender.selectedSegment {
            case 0: if !name.isEmpty { onUsePreset?(name) }
            case 1: if !name.isEmpty { onDeletePreset?(name) }
            default: onApplyLast?()
            }
        }
    }

    @objc private func exportPressed(_ sender: Any?) {
        emit { onExport?() }
    }

    // MARK: - Sync

    /// Rebuilt whenever the library changes; index 0 is always "None".
    func reloadLibrary(selected: String?, presets: [String], selectedPreset: String?) {
        lutPopup.removeAllItems()
        lutPopup.addItem(withTitle: "None")
        for path in LUTLibrary.paths {
            lutPopup.addItem(withTitle: LUTLibrary.name(for: path))
            lutPopup.lastItem?.representedObject = path
        }
        if let selected, let i = LUTLibrary.paths.firstIndex(of: selected) {
            lutPopup.selectItem(at: i + 1)
        } else {
            lutPopup.selectItem(at: 0)
        }

        presetPopup.removeAllItems()
        presetPopup.addItems(withTitles: presets.isEmpty ? ["No presets"] : presets)
        presetPopup.isEnabled = !presets.isEmpty
        if let selectedPreset, presets.contains(selectedPreset) {
            presetPopup.selectItem(withTitle: selectedPreset)
        }
    }

    func show(display: Renderer.DisplayState) {
        // Bypass switches and the LUT readout are safe to refresh at any time:
        // none of them is the control being clicked.
        masterToggle.state = display.gradeEnabled ? .on : .off
        lightHeader.isOn = display.lightOn
        wbHeader.isOn = display.whiteBalanceOn
        tetraHeader.isOn = display.tetraOn
        lutHeader.isOn = display.lutOn

        if let name = display.lutName {
            lutLabel.stringValue = name
            lutSlider.isEnabled = true
        } else {
            lutLabel.stringValue = "No LUT"
            lutSlider.isEnabled = false
        }

        guard !handlingControlAction else { return }
        lutSlider.doubleValue = Double(display.lutAmount) * 100
        let v = TetraLayout.values(from: display.tetra)
        for row in tetraRows { row.value = v[row.corner][row.component] }
        tetraAmount.doubleValue = Double(display.tetraAmount) * 100
        blackRow.value = display.blackPoint
        whiteRow.value = display.whitePoint
        exposureRow.value = display.exposureEV
        contrastRow.value = display.contrast
        pivotRow.value = display.contrastPivot
        wbRows[0].value = display.whiteBalance.x
        wbRows[1].value = display.whiteBalance.y
        wbRows[2].value = display.whiteBalance.z

    }
}
