import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One window, one image, plus its folder for arrow-key navigation.
final class ViewerWindowController: NSWindowController, ImageCanvasDelegate, NSWindowDelegate {
    private let canvas = ImageCanvasView()
    private let readout = ReadoutBar()
    private let scopes = ScopesPanel()
    private let grade = GradePanel()
    /// How far each panel is pushed past its docked position. Animating this
    /// rather than a width makes them *slide* out at full size; animating the
    /// width squashes them toward the corner instead.
    private var scopesOffset: NSLayoutConstraint!
    private var gradeOffset: NSLayoutConstraint!
    private let scopesButton = NSButton()
    private let gradeButton = NSButton()

    private var siblings: [URL] = []
    private var index = 0
    /// Bumped on every load so a slow decode that lands after you've arrowed
    /// past it gets dropped instead of overwriting the image you're now on.
    private var loadToken = 0
    private var scopesToken = 0
    private var hasSizedToImage = false
    private var currentLUTPath: String?
    private var currentPresetName: String?

    private var scopesOpen: Bool {
        get { Preferences.scopesPanelOpen }
        set { Preferences.scopesPanelOpen = newValue }
    }

    private var gradeOpen: Bool {
        get { Preferences.gradePanelOpen }
        set { Preferences.gradePanelOpen = newValue }
    }

    convenience init(url: URL) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 320)
        window.tabbingMode = .disallowed

        // Seamless chrome: a transparent title bar over a window background that
        // is the canvas colour, so the header, the image area and the footer read
        // as one continuous surface.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.background
        window.isOpaque = true

        self.init(window: window)

        window.delegate = self
        buildContentView()
        buildTitlebarAccessory()
        canvas.canvasDelegate = self
        wireScopesPanel()

        // Restores the last size and position. Only the very first window ever
        // opened sizes itself to the image; after that the window you chose wins
        // and the image scales to fit it.
        hasSizedToImage = Preferences.hasSavedWindowFrame
        window.setFrameAutosaveName(Preferences.windowFrameAutosaveName)
        if !hasSizedToImage { window.center() }
        else if let last = AppDelegate.shared?.frontmostViewerFrame, last == window.frame {
            window.setFrameOrigin(NSPoint(x: last.minX + 24, y: last.minY - 24))
        }
        applyPanelVisibility(animated: false)
        // Reload the LUT you were last using, so it survives a relaunch. This has
        // to precede refreshLibrary(), or the popup is built from a library that
        // hasn't been repopulated yet and shows None over a loaded LUT.
        if Preferences.debug { NSLog("Lupp: lastLUTPath = %@", Preferences.lastLUTPath ?? "(nil)") }
        if let path = Preferences.lastLUTPath {
            if FileManager.default.fileExists(atPath: path) {
                applyLUT(at: URL(fileURLWithPath: path), announceFailure: false)
            } else {
                Preferences.lastLUTPath = nil
            }
        }
        refreshLibrary()
        open(url: url)
    }

    private func buildContentView() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.background.cgColor

        // Order matters: grade is added first so the scopes panel draws over it
        // when grade is closed and has slid underneath.
        for v in [canvas, grade, scopes, readout] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        // Clip, so a panel is genuinely out of sight once it has slid past.
        content.clipsToBounds = true

        // Chained: canvas | grade | scopes. Each panel's offset pushes it past
        // the one to its right, so either can be closed independently and the
        // canvas takes back exactly the space that was freed.
        scopesOffset = scopes.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                        constant: Theme.panelWidth)
        gradeOffset = grade.trailingAnchor.constraint(equalTo: scopes.leadingAnchor,
                                                      constant: Theme.panelWidth)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: grade.leadingAnchor),
            canvas.bottomAnchor.constraint(equalTo: readout.topAnchor),

            grade.topAnchor.constraint(equalTo: content.topAnchor),
            grade.bottomAnchor.constraint(equalTo: readout.topAnchor),
            grade.widthAnchor.constraint(equalToConstant: Theme.panelWidth),
            gradeOffset,

            scopes.topAnchor.constraint(equalTo: content.topAnchor),
            scopes.bottomAnchor.constraint(equalTo: readout.topAnchor),
            scopes.widthAnchor.constraint(equalToConstant: Theme.panelWidth),
            scopesOffset,

            readout.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            readout.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            readout.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            readout.heightAnchor.constraint(equalToConstant: ReadoutBar.height),
        ])
    }

    /// The scopes toggle lives in the title bar's right-hand accessory slot, which
    /// is how AppKit puts a control up there without a custom title bar.
    private func buildTitlebarAccessory() {
        gradeButton.toolTip = "Colour — LUT, tetrahedral grade, presets, export"
        gradeButton.action = #selector(toggleGrade(_:))

        scopesButton.image = NSImage(systemSymbolName: "chart.bar.xaxis",
                                     accessibilityDescription: "Inspector")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        scopesButton.toolTip = "Inspector — histogram, waveform, vectorscope, CIE"
        scopesButton.action = #selector(toggleScopes(_:))

        for b in [gradeButton, scopesButton] {
            b.bezelStyle = .texturedRounded
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.target = self
            b.translatesAutoresizingMaskIntoConstraints = false
        }

        // Left button, left panel: the buttons sit in the order the panels do.
        let row = NSStackView(views: [gradeButton, scopesButton])
        row.orientation = .horizontal
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 68, height: 28))
        host.addSubview(row)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 68),
            host.heightAnchor.constraint(equalToConstant: 28),
            row.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
        ])

        let acc = NSTitlebarAccessoryViewController()
        acc.layoutAttribute = .right
        acc.view = host
        window?.addTitlebarAccessoryViewController(acc)
    }

    private func wireScopesPanel() {
        scopes.onChannel = { [weak self] ch in
            self?.canvas.display.channel = ch
        }
        scopes.onClipping = { [weak self] on in
            self?.canvas.display.showClipping = on
        }
        scopes.onFalseColour = { [weak self] on in
            self?.canvas.display.falseColour = on
        }
        grade.onExport = { [weak self] in self?.exportImage(nil) }
        grade.onLoadLUT = { [weak self] in self?.loadLUT() }
        grade.onClearLUT = { [weak self] in self?.turnLUTOff() }
        grade.onLUTAmount = { [weak self] a in
            self?.canvas.display.lutAmount = a
            self?.rememberGrade()
        }
        grade.onPickLUT = { [weak self] path in
            guard let self else { return }
            if let path { self.applyLUT(at: URL(fileURLWithPath: path), announceFailure: true) }
            else { self.turnLUTOff() }
            self.refreshLibrary()
        }
        grade.onRemoveLUT = { [weak self] path in
            guard let self else { return }
            LUTLibrary.remove(path)
            if self.currentLUTPath == path { self.turnLUTOff() }
            self.refreshLibrary()
        }
        grade.onTetra = { [weak self] corners, amount, enabled in
            guard let self else { return }
            self.canvas.display.tetra = corners
            self.canvas.display.tetraAmount = amount
            self.canvas.display.tetraEnabled = enabled
            self.rememberGrade()
        }
        grade.onLight = { [weak self] ev, wb, contrast, pivot in
            guard let self else { return }
            self.canvas.display.exposureEV = ev
            self.canvas.display.whiteBalance = wb
            self.canvas.display.contrast = contrast
            self.canvas.display.contrastPivot = pivot
            self.rememberGrade()
            self.recomputeScopes()
        }
        grade.onSavePreset = { [weak self] in self?.savePreset() }
        grade.onUsePreset = { [weak self] name in
            guard let self, let p = PresetStore.all.first(where: { $0.name == name }) else { return }
            self.apply(preset: p)
        }
        grade.onDeletePreset = { [weak self] name in
            PresetStore.delete(named: name)
            if self?.currentPresetName == name { self?.currentPresetName = nil }
            self?.refreshLibrary()
        }
        grade.onApplyLast = { [weak self] in
            guard let self, let p = PresetStore.last else { NSSound.beep(); return }
            self.apply(preset: p)
        }
        scopes.onViewTransform = { [weak self] t in
            guard let self else { return }
            Preferences.setViewTransform(t, sceneLinear: self.currentIsSceneLinear)
            self.canvas.display.viewTransform = t
            self.syncPanelControls()
        }
    }

    private var currentIsSceneLinear: Bool { canvas.image?.isSceneLinear ?? false }

    // MARK: - Grade, LUT library, presets

    private func turnLUTOff() {
        canvas.clearLUT()
        currentLUTPath = nil
        Preferences.lastLUTPath = nil
        rememberGrade()
    }

    private func refreshLibrary() {
        grade.reloadLibrary(selected: currentLUTPath,
                             presets: PresetStore.all.map(\.name),
                             selectedPreset: currentPresetName)
    }

    /// Every grade change updates "last", so a new image can be given the look
    /// you were just working in without having to name it first.
    private func rememberGrade() {
        var p = Preset.from(canvas.display, lutPath: currentLUTPath)
        p.name = ""
        PresetStore.last = p
    }

    private func apply(preset p: Preset) {
        var d = canvas.display
        p.apply(to: &d)
        canvas.display = d
        if let path = p.lutPath, FileManager.default.fileExists(atPath: path) {
            applyLUT(at: URL(fileURLWithPath: path), announceFailure: false)
        } else {
            canvas.clearLUT()
            currentLUTPath = nil
        }
        currentPresetName = p.name.isEmpty ? nil : p.name
        refreshLibrary()
        syncPanelControls()
    }

    private func savePreset() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Preset name"
        field.stringValue = currentPresetName ?? ""
        let a = NSAlert()
        a.messageText = "Save this grade as a preset"
        a.informativeText = "Stores the view transform, exposure, LUT choice and the tetrahedral corners. Window size and zoom aren’t included."
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        var p = Preset.from(canvas.display, lutPath: currentLUTPath)
        p.name = name
        PresetStore.save(p)
        currentPresetName = name
        refreshLibrary()
    }

    private func loadLUT() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // .cube has no registered system type, so declare one for the filter.
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.message = "Choose a .cube LUT"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyLUT(at: url, announceFailure: true)
        refreshLibrary()
    }

    @discardableResult
    private func applyLUT(at url: URL, announceFailure: Bool) -> Bool {
        do {
            let lut = try CubeLUT.parse(url: url)
            guard canvas.loadLUT(lut) else {
                if Preferences.debug { NSLog("Lupp: GPU refused LUT %@ (size %d)", url.lastPathComponent, lut.size) }
                throw CubeLUT.ParseError.unreadable(url)
            }
            if Preferences.debug { NSLog("Lupp: LUT loaded %@ size %d", url.lastPathComponent, lut.size) }
            var name = "\(lut.title) · \(lut.size)³"
            if lut.wasOneDimensional { name += " · from 1D" }
            canvas.display.lutName = name
            currentLUTPath = url.path
            Preferences.lastLUTPath = url.path
            LUTLibrary.add(url.path)
            rememberGrade()
            refreshLibrary()
            return true
        } catch {
            if Preferences.debug { NSLog("Lupp: LUT failed %@ — %@", url.lastPathComponent, error.localizedDescription) }
            if announceFailure {
                let a = NSAlert()
                a.messageText = "Couldn’t load that LUT"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
            return false
        }
    }

    private func syncPanelControls() {
        scopes.show(display: canvas.display,
                    detected: canvas.image.map(ViewTransform.detected(for:)),
                    sceneLinear: currentIsSceneLinear)
        grade.show(display: canvas.display)
    }

    // MARK: - Scopes

    @objc func toggleScopes(_ sender: Any?) {
        scopesOpen.toggle()
        applyPanelVisibility(animated: true)
    }

    @objc func toggleGrade(_ sender: Any?) {
        gradeOpen.toggle()
        applyPanelVisibility(animated: true)
    }

    private func applyPanelVisibility(animated: Bool) {
        // Grey when closed, full strength when open — the accent colour read as
        // an alert rather than as a state, which is not what a view toggle says.
        scopesButton.contentTintColor = scopesOpen ? .labelColor : .secondaryLabelColor
        gradeButton.image = Theme.gradeIcon(active: gradeOpen)

        let scopesTarget: CGFloat = scopesOpen ? 0 : Theme.panelWidth
        let gradeTarget: CGFloat = gradeOpen ? 0 : Theme.panelWidth
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                scopesOffset.animator().constant = scopesTarget
                gradeOffset.animator().constant = gradeTarget
                window?.contentView?.layoutSubtreeIfNeeded()
            }
        } else {
            scopesOffset.constant = scopesTarget
            gradeOffset.constant = gradeTarget
        }
        if scopesOpen { recomputeScopes() }
    }

    /// Whole-image reductions, so they run off the main thread and only while the
    /// panel is actually open — a closed panel should cost nothing.
    private func recomputeScopes() {
        guard scopesOpen, let img = canvas.image else {
            scopes.update(with: nil, image: nil)
            return
        }
        scopesToken += 1
        let token = scopesToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Scopes.compute(from: img)
            DispatchQueue.main.async {
                guard let self, self.scopesToken == token else { return }
                self.scopes.update(with: result, image: img)
            }
        }
    }

    // MARK: - Loading

    func open(url: URL) {
        siblings = FolderScanner.siblings(of: url)
        index = siblings.firstIndex(of: url) ?? 0
        loadCurrent()
    }

    private func loadCurrent() {
        guard siblings.indices.contains(index) else { return }
        let url = siblings[index]
        loadToken += 1
        let token = loadToken

        window?.representedURL = url
        window?.title = url.lastPathComponent
        window?.subtitle = siblings.count > 1 ? "\(index + 1) of \(siblings.count)" : ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try ImageLoader.load(url: url) }
            DispatchQueue.main.async {
                guard let self, self.loadToken == token else { return }
                switch result {
                case .success(let img):
                    self.present(img)
                case .failure(let err):
                    self.canvas.show(nil)
                    self.scopes.update(with: nil, image: nil)
                    self.window?.subtitle = err.localizedDescription
                }
            }
        }
    }

    private func present(_ img: FloatImage) {
        if !hasSizedToImage {
            hasSizedToImage = true
            sizeWindow(to: img)
        }
        canvas.show(img)
        // Colour space comes from the file; the view transform is chosen from what
        // kind of file it is, because no file records one.
        canvas.display.viewTransform = Preferences.viewTransform(sceneLinear: img.isSceneLinear)
        syncPanelControls()
        recomputeScopes()

        window?.subtitle = subtitleForCurrent()
        window?.makeFirstResponder(canvas)
    }

    private func sizeWindow(to img: FloatImage) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let avail = screen.visibleFrame.insetBy(dx: 60, dy: 60)
        let native = CGSize(width: CGFloat(img.width) / max(screen.backingScaleFactor, 1),
                            height: CGFloat(img.height) / max(screen.backingScaleFactor, 1))
        let chrome = (scopesOpen ? Theme.panelWidth : 0) + (gradeOpen ? Theme.panelWidth : 0)
        let fit = min(1, min((avail.width - chrome) / native.width,
                             (avail.height - ReadoutBar.height) / native.height))
        let size = NSSize(width: max(360, native.width * fit) + chrome,
                          height: max(240, native.height * fit) + ReadoutBar.height)
        window.setContentSize(size)
        window.center()
    }

    private func shortType(_ uti: String) -> String {
        let tail = uti.split(separator: ".").last.map(String.init) ?? uti
        return tail.replacingOccurrences(of: "-image", with: "").uppercased()
    }

    // MARK: - ImageCanvasDelegate

    func canvasReadoutChanged(_ c: ImageCanvasView) {
        readout.update(pixel: c.cursorPixel, value: c.cursorValue,
                       zoomPercent: c.zoomPercent, exposureEV: c.exposureEV,
                       downsampled: c.isDownsampledView)
    }

    func canvasDisplayChanged(_ c: ImageCanvasView) {
        syncPanelControls()
    }

    /// A dropped file replaces what this window is showing; extra files beyond
    /// the first open in their own windows, matching what Finder does.
    func canvas(_ c: ImageCanvasView, wantsToOpen urls: [URL]) {
        guard let first = urls.first else { return }
        hasSizedToImage = true          // keep the window the user's, not the file's
        open(url: first)
        for extra in urls.dropFirst() { AppDelegate.shared?.present(extra) }
    }

    func canvasWantsNavigation(_ c: ImageCanvasView, by delta: Int) {
        guard siblings.count > 1 else { return }
        index = (index + delta + siblings.count) % siblings.count
        loadCurrent()
    }

    // MARK: - Export

    /// Writes what is on screen: same shader, same settings, full resolution.
    @objc func exportImage(_ sender: Any?) {
        guard let img = canvas.image else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .tiff, .jpeg]
        panel.nameFieldStringValue =
            img.url.deletingPathExtension().lastPathComponent + "-lupp.png"
        panel.message = "Export the image as displayed — view transform, LUT, grade and exposure baked in."
        guard panel.runModal() == .OK, let out = panel.url else { return }

        let ext = out.pathExtension.lowercased()
        // 16 bits for TIFF, where the extra depth is the reason to choose it;
        // 8 for PNG and JPEG, where it mostly just doubles the file.
        let bits = (ext == "tif" || ext == "tiff") ? 16 : 8
        let type: String
        switch ext {
        case "tif", "tiff": type = UTType.tiff.identifier
        case "jpg", "jpeg": type = UTType.jpeg.identifier
        default:            type = UTType.png.identifier
        }

        guard let cg = canvas.exportImage(bitDepth: bits),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil)
        else {
            let a = NSAlert()
            a.messageText = "Couldn’t export"
            a.informativeText = "Rendering the image for export failed."
            a.runModal()
            return
        }
        var props: [CFString: Any] = [:]
        if type == UTType.jpeg.identifier { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            let a = NSAlert()
            a.messageText = "Couldn’t write \(out.lastPathComponent)"
            a.runModal()
        }
    }

    // MARK: - Menu actions

    @objc func zoomIn(_ sender: Any?)      { canvas.zoomStep(1.25) }
    @objc func zoomOut(_ sender: Any?)     { canvas.zoomStep(1 / 1.25) }
    @objc func zoomActualSize(_ sender: Any?) { canvas.zoomToActualSize() }
    @objc func zoomFit(_ sender: Any?)     { canvas.zoomToFit() }
    @objc func nextImage(_ sender: Any?)   { canvasWantsNavigation(canvas, by: 1) }
    @objc func previousImage(_ sender: Any?) { canvasWantsNavigation(canvas, by: -1) }
    @objc func increaseExposure(_ sender: Any?) { canvas.exposureEV += 0.25; canvasReadoutChanged(canvas) }
    @objc func decreaseExposure(_ sender: Any?) { canvas.exposureEV -= 0.25; canvasReadoutChanged(canvas) }
    @objc func resetExposure(_ sender: Any?)    { canvas.exposureEV = 0; canvasReadoutChanged(canvas) }
    @objc func toggleClipping(_ sender: Any?)   { canvas.display.showClipping.toggle() }
    @objc func toggleFalseColour(_ sender: Any?) { canvas.display.falseColour.toggle() }

    /// Re-read the folder when the window comes forward: files added or removed
    /// while it was in the background would otherwise leave "n of m" describing
    /// a folder that no longer exists in that shape.
    func windowDidBecomeKey(_ notification: Notification) {
        guard siblings.indices.contains(index) else { return }
        let current = siblings[index]
        let fresh = FolderScanner.siblings(of: current)
        guard fresh != siblings else { return }
        siblings = fresh
        index = fresh.firstIndex(of: current) ?? 0
        if !fresh.contains(current) {
            loadCurrent()
        } else {
            window?.subtitle = subtitleForCurrent()
        }
    }

    private func subtitleForCurrent() -> String {
        guard let img = canvas.image else { return "" }
        var s = "\(img.fullWidth) × \(img.fullHeight)"
        s += " · \(shortType(img.typeIdentifier)) \(img.sourceBitDepth)-bit"
        s += " · \(img.sourceColorSpace)"
        if img.isHDR { s += " · HDR to \(String(format: "%.2f", img.maxComponent))" }
        if siblings.count > 1 { s += "  ·  \(index + 1) of \(siblings.count)" }
        return s
    }

    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared?.forget(self)
    }
}
