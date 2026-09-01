import AppKit
import simd

/// The colour panel: LUT, tetrahedral grade, presets and export.
///
/// Separate from the inspector because the two answer different questions —
/// this one changes the pixels, the inspector only reports on them — and because
/// wanting to grade is not the same as wanting to watch scopes while you do it.
final class GradePanel: SidePanel {
    /// Which part of the chain a bypass switch belongs to.
    enum Section { case master, light, whiteBalance, tetra, saturation, lut, crop }

    var onLoadLUT: (() -> Void)?
    var onClearLUT: (() -> Void)?
    var onLUTAmount: ((Float) -> Void)?
    var onPickLUT: ((String?) -> Void)?
    var onRemoveLUT: ((String) -> Void)?
    var onTetra: ((Renderer.TetraCorners, Float, Bool) -> Void)?
    var onSaturation: ((Float) -> Void)?
    /// exposure EV, white balance gains, contrast, pivot, black point, white point
    var onLight: ((Float, SIMD3<Float>, Float, Float, Float, Float) -> Void)?
    var onSavePreset: (() -> Void)?
    var onUsePreset: ((String) -> Void)?
    var onDeletePreset: ((String) -> Void)?
    var onApplyLast: (() -> Void)?
    var onExport: (() -> Void)?
    var onBypass: ((Section, Bool) -> Void)?
    /// Aspect ratio as width/height, or nil for free.
    var onCropAspect: ((Double?) -> Void)?
    var onCropReset: (() -> Void)?
    var onCropApply: ((Bool) -> Void)?
    var onLUTInput: ((LUTInput) -> Void)?

    private let lutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let lutButtons = NSSegmentedControl(labels: ["Add…", "Remove"],
                                                trackingMode: .momentary, target: nil, action: nil)
    private let lutLabel = ThemedLabel("No LUT", role: .tertiary, size: 9)
    private let lutInput = NSPopUpButton(frame: .zero, pullsDown: false)
    private let lutSlider = FineSlider()

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
    private let tetraAmount = FineSlider()
    /// 0 is monochrome, 1 unchanged, 2 twice as far out — so the handle sits in
    /// the middle at neutral like every other row here.
    private lazy var saturationRow = LabelledSliderRow(label: "Saturation", initial: 1, span: 1)
    private let savePresetButton = NSButton(title: "Save Preset…", target: nil, action: nil)

    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let presetButtons = NSSegmentedControl(labels: ["Use", "Delete", "Apply Last"],
                                                   trackingMode: .momentary, target: nil, action: nil)

    private let exportButton = NSButton(title: "Export as Displayed…",
                                        target: nil, action: nil)

    private var masterHeader: SectionHeader!
    private var cropHeader: SectionHeader!
    private let cropAspect = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var cropSize = caption("Whole image")
    private let cropApply = NSSegmentedControl(labels: ["Overlay", "Applied"],
                                               trackingMode: .selectOne,
                                               target: nil, action: nil)

    /// Width/height, nil meaning free.
    private static let aspects: [(String, Double?)] = [
        ("Free", nil), ("Original", 0), ("1:1", 1), ("4:3", 4.0/3), ("3:2", 1.5),
        ("16:9", 16.0/9), ("2.39:1", 2.39), ("3:4", 0.75), ("2:3", 2.0/3), ("9:16", 9.0/16),
    ]
    /// The controls each bypass owns, so they can be dimmed when it is off — a
    /// bypassed section should look inert, or you cannot tell at a glance which
    /// part of the chain is actually doing anything.
    private var sectionViews: [Section: [NSView]] = [:]
    private var lightHeader: SectionHeader!
    private var wbHeader: SectionHeader!
    private var tetraHeader: SectionHeader!
    private var saturationHeader: SectionHeader!
    private var lutHeader: SectionHeader!

    override init() {
        super.init()

        style(lutPopup)
        lutPopup.target = self
        lutPopup.action = #selector(lutPicked(_:))
        style(lutButtons, size: .small, font: 10)
        lutButtons.target = self
        lutButtons.action = #selector(lutButtonPressed(_:))
        lutSlider.minValue = 0; lutSlider.maxValue = 100; lutSlider.doubleValue = 100
        style(lutInput)
        lutInput.target = self
        lutInput.action = #selector(lutInputChanged(_:))
        for i in LUTInput.allCases {
            lutInput.addItem(withTitle: i.label)
            lutInput.lastItem?.tag = i.rawValue
        }
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
        tetraAmount.minValue = 0; tetraAmount.maxValue = 100; tetraAmount.doubleValue = 100
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
        let lutNote = caption("A display LUT is the last thing applied — the look laid over a finished grade, so it will put colour back into anything saturation took out. Choosing a log input instead means the LUT is the display rendering: it gets log-encoded scene values and its output is taken as final, so it stands in for the view transform rather than tone-mapping twice, and necessarily happens earlier in the chain.")
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
        saturationRow.onChange = { [weak self] in
            guard let self else { return }
            self.emit { self.onSaturation?(self.saturationRow.value) }
        }
        saturationHeader = sectionHeader("Saturation",
                                         toggle: { [weak self] on in
                                             self?.emit { self?.onBypass?(.saturation, on) } },
                                         reset: { [weak self] in
                                             self?.saturationRow.resetToDefault()
                                             self?.emit { self?.onSaturation?(1) } })
        tetraHeader = sectionHeader("Tetrahedral",
                                    toggle: { [weak self] on in
                                        self?.emit { self?.onBypass?(.tetra, on) } },
                                    reset: { [weak self] in self?.resetTetra() })
        cropHeader = sectionHeader("Crop",
                                   toggle: { [weak self] on in
                                       self?.emit { self?.onBypass?(.crop, on) } },
                                   reset: { [weak self] in self?.emit { self?.onCropReset?() } })
        cropHeader.isOn = false
        style(cropAspect)
        cropAspect.target = self
        cropAspect.action = #selector(cropAspectChanged(_:))
        for (name, _) in GradePanel.aspects { cropAspect.addItem(withTitle: name) }
        style(cropApply, size: .small, font: 10)
        cropApply.selectedSegment = 0
        cropApply.target = self
        cropApply.action = #selector(cropApplyChanged(_:))

        lutHeader = sectionHeader("LUT",
                                  toggle: { [weak self] on in
                                      self?.emit { self?.onBypass?(.lut, on) } },
                                  reset: { [weak self] in self?.emit { self?.onClearLUT?() } })

        masterHeader = sectionHeader("Grading",
                                     toggle: { [weak self] on in
                                         self?.emit { self?.onBypass?(.master, on) } },
                                     size: 12,
                                     reset: { [weak self] in self?.resetEverything() })

        let cropNote = caption("Drag the rectangle on the image; hold Shift for a tenth-speed drag with a magnifier. Applied makes the crop the working image — zoom, scopes and readout all follow it — without touching the source, so switching back to Overlay costs nothing. Export writes the crop at its own pixel size either way.")

        var column: [NSView] = [
            masterHeader,
            separator(),
            lightHeader, blackRow, whiteRow, exposureRow, contrastRow, pivotRow,
            wbHeader, wbRows[0], wbRows[1], wbRows[2],
            lightNote,
            separator(),
            tetraHeader,
        ]
        column += tetraRowViews
        column += [caption("Mix"), tetraAmount, tetraNote]
        column += [separator(), saturationHeader, saturationRow,
                   caption("How much colour survives, taken after the cube warp — so pulling it to zero renders the luma of whatever the corners just did, and the six hue corners become a channel mixer for black and white.")]

        // Order down the panel is the order the pixels travel: light, then the
        // cube warp, then saturation, then a display LUT last of all.
        //
        // Crop is not a colour operation and sits below the whole chain, next to
        // export — which is the thing it most affects, since export writes the
        // crop at its own pixel size.
        column += [separator(),
                   lutHeader, lutPopup, lutButtons, lutLabel, lutInput, lutSlider, lutNote,
                   separator(),
                   sectionLabel("Presets"), presetPopup, presetButtons, savePresetButton,
                   separator(),
                   cropHeader, cropAspect, cropApply, cropSize, cropNote,
                   separator(),
                   sectionLabel("Export"), exportButton, exportNote]

        sectionViews[.light] = [blackRow, whiteRow, exposureRow, contrastRow, pivotRow]
        sectionViews[.whiteBalance] = wbRows
        sectionViews[.tetra] = tetraRowViews + ([tetraAmount] as [NSView])
        sectionViews[.saturation] = [saturationRow]
        sectionViews[.lut] = [lutPopup, lutButtons, lutLabel, lutInput, lutSlider]
        sectionViews[.crop] = [cropAspect, cropApply, cropSize]

        // Built in named pieces: one literal mixing this many control types is
        // more than the type checker will do in reasonable time.
        var wide: [NSView] = [lutPopup, lutButtons, lutLabel, lutInput, lutSlider, lutNote]
        wide += [tetraAmount, tetraNote, lightNote, savePresetButton, saturationRow] as [NSView]
        wide += [presetPopup, presetButtons, exportButton, exportNote] as [NSView]
        wide += [masterHeader, lightHeader, wbHeader, tetraHeader, saturationHeader, lutHeader] as [NSView]
        wide += [cropHeader, cropAspect, cropApply, cropSize, cropNote] as [NSView]
        wide += tetraRowViews
        wide += lightRows as [NSView]
        wide += balanceRows as [NSView]
        install(column: column, fullWidth: wide)
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

    /// Resetting the whole grade covers light, white balance, the cube,
    /// saturation and the LUT — every section that has to be put back must also
    /// *emit*, or the control returns to its default while the renderer keeps
    /// the old value and the panel starts lying about the picture.
    ///
    /// The crop is the one thing left alone. Everything else here is a value you
    /// dialled and can dial again; a crop is a composition you judged by eye,
    /// and throwing it away is not something a small reset arrow should be able
    /// to do by surprise. It keeps its own reset.
    private func resetEverything() {
        for row in lightAndBalanceRows { row.resetToDefault() }
        saturationRow.resetToDefault()
        for row in tetraRows { row.resetToDefault() }
        tetraAmount.doubleValue = 100
        lightChanged()
        tetraChanged(nil)
        emit { onSaturation?(1) }
        emit { onClearLUT?() }
    }

    @objc private func cropApplyChanged(_ sender: NSSegmentedControl) {
        emit { onCropApply?(sender.selectedSegment == 1) }
    }

    @objc private func cropAspectChanged(_ sender: NSPopUpButton) {
        let a = GradePanel.aspects[min(sender.indexOfSelectedItem, GradePanel.aspects.count - 1)].1
        emit { onCropAspect?(a) }
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
            if sender.selectedSegment == 0 { onLoadLUT?() }
            else if let path = lutPopup.selectedItem?.representedObject as? String {
                onRemoveLUT?(path)
            }
        }
    }

    @objc private func lutInputChanged(_ sender: NSPopUpButton) {
        guard let i = LUTInput(rawValue: sender.selectedTag()) else { return }
        emit { onLUTInput?(i) }
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

    func showCropSize(_ text: String) { cropSize.stringValue = text }

    func show(display: Renderer.DisplayState) {
        // Bypass switches and the LUT readout are safe to refresh at any time:
        // none of them is the control being clicked.
        masterHeader.isOn = display.gradeEnabled
        cropHeader.isOn = display.cropEnabled
        cropApply.isEnabled = display.cropEnabled

        // Dim what is switched off. The master dims everything, so a bypassed
        // section inside a bypassed grade doesn't read as if it were live.
        let master = display.gradeEnabled
        let on: [Section: Bool] = [
            .light: display.lightOn, .whiteBalance: display.whiteBalanceOn,
            .tetra: display.tetraOn, .lut: display.lutOn, .crop: display.cropEnabled,
        ]
        for (section, views) in sectionViews {
            // Crop is not part of the grade chain, so the master doesn't reach it.
            let live = (on[section] ?? true) && (section == .crop || master)
            for v in views { v.alphaValue = live ? 1 : 0.4 }
        }
        for header in [lightHeader, wbHeader, tetraHeader, saturationHeader, lutHeader] {
            header?.alphaValue = master ? 1 : 0.55
        }
        if !handlingControlAction { cropApply.selectedSegment = display.cropApplied ? 1 : 0 }
        lightHeader.isOn = display.lightOn
        wbHeader.isOn = display.whiteBalanceOn
        tetraHeader.isOn = display.tetraOn
        saturationHeader.isOn = display.saturationOn
        if !handlingControlAction { saturationRow.value = display.saturation }
        lutHeader.isOn = display.lutOn

        if let name = display.lutName {
            lutLabel.stringValue = name
            lutSlider.isEnabled = true
            lutInput.isEnabled = true
        } else {
            lutLabel.stringValue = "No LUT"
            lutSlider.isEnabled = false
            lutInput.isEnabled = false
        }
        if !handlingControlAction { lutInput.selectItem(withTag: display.lutInput.rawValue) }

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
