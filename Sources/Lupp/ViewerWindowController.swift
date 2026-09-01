import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A window that lets go of a text field when you click somewhere else.
///
/// AppKit only moves the keyboard when the thing you clicked asks for it, so
/// clicking a panel's background, a label, or the picture itself left a
/// half-typed number still holding first responder — and with it every bare-key
/// shortcut, with nothing on screen to say why. Handling it at the window means
/// one rule for every click, rather than each view remembering to be polite.
final class ViewerWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           let editor = firstResponder as? NSText,
           let content = contentView {
            // The field editor belongs to the control being edited; clicks
            // inside that control are part of editing, not a departure from it.
            let owner = (editor.delegate as? NSView) ?? editor
            let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
            let staying = hit.map { $0 === owner || $0.isDescendant(of: owner) } ?? false
            if !staying {
                makeFirstResponder(nil)
                // A panel's background doesn't want the keyboard, so hand it to
                // the canvas rather than leaving it with the window and the
                // bare-key shortcuts half alive.
                if hit?.acceptsFirstResponder != true, let fallback = initialFirstResponder {
                    makeFirstResponder(fallback)
                }
            }
        }
        super.sendEvent(event)
    }
}

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
    /// Which way you were last going, so the prefetch can read ahead rather than
    /// behind. Starts forward, which is the direction opening a folder implies.
    private var lastNavigationDelta = 1
    /// Bumped on every load so a slow decode that lands after you've arrowed
    /// past it gets dropped instead of overwriting the image you're now on.
    private var loadToken = 0
    private var scopesInFlight = false
    private var scopesPending = false
    /// Facts about the file, measured once on load — the grade can't change them.
    private var sourceStats: Scopes.Stats?
    private var hasSizedToImage = false
    private var currentLUTPath: String?
    private var currentPresetName: String?
    /// Held between asking for an image and it arriving, since the grade can only
    /// be applied once there is something to apply it to.
    private var pendingSession: Session?

    private var scopesOpen: Bool {
        get { Preferences.scopesPanelOpen }
        set { Preferences.scopesPanelOpen = newValue }
    }

    private var gradeOpen: Bool {
        get { Preferences.gradePanelOpen }
        set { Preferences.gradePanelOpen = newValue }
    }

    /// Opens a saved session: the image it names, with the work restored.
    convenience init(session url: URL) {
        // A placeholder image path keeps the designated path single; the session
        // immediately replaces it with the one it actually refers to.
        self.init(url: url, deferOpening: true)
        open(session: url)
    }

    convenience init(url: URL) {
        self.init(url: url, deferOpening: false)
    }

    /// Everything needed to build this window again: which picture, and the work
    /// standing on it. Used when the interface size changes, since the panels
    /// size themselves as they are built and there is no honest way to restretch
    /// them in place.
    func rebuildSnapshot() -> (session: Session, image: URL)? {
        guard let img = canvas.image else { return nil }
        return (Session.from(canvas.display, image: img.url, lutPath: currentLUTPath), img.url)
    }

    /// A window built to receive work that already exists in memory, rather than
    /// to open a file from scratch.
    convenience init(restoring session: Session, image: URL) {
        self.init(url: image, deferOpening: true)
        restore(session, image: image)
    }

    /// Open a picture with work already attached, without going via a file.
    func restore(_ session: Session, image: URL) {
        pendingSession = session
        hasSizedToImage = true      // the window is the user's, not the session's
        open(url: image)
    }

    private convenience init(url: URL, deferOpening: Bool) {
        let window = ViewerWindow(
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
        // Where the keyboard goes when nothing else has claimed it — after a
        // field is finished with, and at the start.
        window.initialFirstResponder = canvas
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
        LUTLibrary.migrateStrays()
        // The backdrop is a stored preference, so a new window has to adopt it
        // rather than starting at whatever the defaults happened to be.
        applyBackgroundEverywhere()
        // Deliberately no LUT is loaded here. Opening an image shows the image;
        // a look is something you ask for, per image, from the library or a preset.
        refreshLibrary()
        if !deferOpening { open(url: url) }
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
            .withSymbolConfiguration(.init(pointSize: Theme.scaled(14), weight: .medium))
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
        // One rule for both panels: after any control action settles, re-read
        // everything. Individual actions never have to remember what else they
        // might have changed.
        let resync: () -> Void = { [weak self] in
            self?.refreshLibrary()
            self?.syncPanelControls()
        }
        grade.onResync = resync
        scopes.onResync = resync

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
            self.canvas.display.tetraActive = enabled
            self.rememberGrade()
        }
        grade.onLight = { [weak self] ev, wb, contrast, pivot, black, white in
            guard let self else { return }
            var d = self.canvas.display
            d.exposureEV = ev
            d.whiteBalance = wb
            d.contrast = contrast
            d.contrastPivot = pivot
            d.blackPoint = black
            d.whitePoint = white
            self.canvas.display = d          // one write, one refresh
            self.rememberGrade()
        }
        grade.onBypass = { [weak self] section, on in
            guard let self else { return }
            var d = self.canvas.display
            switch section {
            case .master:       d.gradeEnabled = on
            case .light:        d.lightOn = on
            case .whiteBalance: d.whiteBalanceOn = on
            case .tetra:        d.tetraOn = on
            case .lut:          d.lutOn = on
            case .crop:         d.cropEnabled = on
            }
            self.canvas.display = d
        }
        grade.onLUTInput = { [weak self] input in
            self?.canvas.display.lutInput = input
            Preferences.lutInput = input.rawValue
            self?.rememberGrade()
        }
        grade.onCropApply = { [weak self] applied in
            self?.canvas.display.cropApplied = applied
        }
        grade.onCropReset = { [weak self] in
            guard let self else { return }
            var d = self.canvas.display
            d.crop = SIMD4<Float>(0, 0, 1, 1)
            d.cropApplied = false
            self.canvas.display = d
        }
        grade.onCropAspect = { [weak self] aspect in
            guard let self, let img = self.canvas.image else { return }
            guard var a = aspect else {                   // Free
                self.canvas.cropAspect = nil
                return
            }
            if a == 0 { a = Double(img.width) / Double(img.height) }   // Original
            self.canvas.cropAspect = a
            var c = self.canvas.display.crop
            // Fit the requested ratio inside the current crop, keeping its centre,
            // so choosing a ratio refines what you have rather than starting over.
            let cx = Double(c.x) + Double(c.z) / 2
            let cy = Double(c.y) + Double(c.w) / 2
            let pxW = Double(img.width), pxH = Double(img.height)
            var w = Double(c.z), h = Double(c.w)
            if (w * pxW) / (h * pxH) > a { w = (h * pxH * a) / pxW } else { h = (w * pxW / a) / pxH }
            c.z = Float(min(w, 1)); c.w = Float(min(h, 1))
            c.x = Float(min(max(cx - Double(c.z) / 2, 0), 1 - Double(c.z)))
            c.y = Float(min(max(cy - Double(c.w) / 2, 0), 1 - Double(c.w)))
            self.canvas.display.crop = c
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
        rememberGrade()
        refreshLibrary()
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
        // The panel's deferred resync picks the controls up once the click that
        // triggered this has finished.
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
            // Copied into the app's storage on the way in, so the library keeps
            // working after the original is tidied away.
            let stored = LUTLibrary.add(importing: url)
            currentLUTPath = stored
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
        if let img = canvas.image {
            let c = canvas.display.cropPixels(imageWidth: img.width, imageHeight: img.height)
            grade.showCropSize(canvas.display.cropEnabled
                ? "\(c.w) × \(c.h) px   from \(img.width) × \(img.height)"
                : "Whole image")
        }
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
        scopesButton.contentTintColor = scopesOpen ? Theme.text(.primary) : Theme.text(.tertiary)
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

    /// Re-measure the scopes from a fresh graded render.
    ///
    /// Coalesced rather than queued: while one pass is in flight another request
    /// only sets a flag, and at most one more runs when it finishes. Dragging a
    /// slider fires these continuously, and a queue would fall further behind the
    /// longer you dragged — this instead always measures the *latest* state and
    /// simply skips the intermediate ones it couldn't keep up with.
    private func recomputeScopes() {
        guard scopesOpen, canvas.image != nil else {
            scopes.update(with: nil, image: nil)
            return
        }
        if scopesInFlight { scopesPending = true; return }
        scopesInFlight = true

        // The render has to happen here: Metal work belongs with the renderer, and
        // it is sub-millisecond at this size. Only the reduction goes off-thread.
        guard let sampled = canvas.renderSampled(maxDimension: Scopes.sampleExtent),
              let stats = sourceStats else {
            scopesInFlight = false
            return
        }
        let img = canvas.image
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Scopes.compute(graded: sampled.data, width: sampled.width,
                                        height: sampled.height, stats: stats)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scopes.update(with: result, image: img)
                self.scopesInFlight = false
                if self.scopesPending {
                    self.scopesPending = false
                    self.recomputeScopes()
                }
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

        ImageStore.shared.load(url) { [weak self] result in
            guard let self, self.loadToken == token else { return }
            switch result {
            case .success(let img):
                self.present(img)
            case .failure(let err):
                self.sourceStats = nil
                self.canvas.show(nil)
                self.scopes.update(with: nil, image: nil)
                self.window?.subtitle = err.localizedDescription
            }
            self.prefetchNeighbours()
        }
    }

    // MARK: - Turning a picture the right way up

    @objc func rotateImageLeft(_ sender: Any?)  { rotateImage(clockwise: false) }
    @objc func rotateImageRight(_ sender: Any?) { rotateImage(clockwise: true) }

    /// For a file that is simply wrong about which way up it is.
    ///
    /// The rotation replaces the cached copy, so it holds while you look at
    /// other pictures and come back, but it is never written to disk — the
    /// source file is not ours to correct. A crop is dropped, because its
    /// coordinates described a frame that no longer exists; the grade is kept,
    /// because turning a picture is not an edit to it.
    private func rotateImage(clockwise: Bool) {
        guard let img = canvas.image else { NSSound.beep(); return }
        guard let turned = ImageLoader.rotated(img, clockwise: clockwise) else {
            NSSound.beep(); return
        }
        if canvas.display.cropEnabled || canvas.display.cropApplied {
            var d = canvas.display
            d.cropEnabled = false
            d.cropApplied = false
            d.crop = SIMD4(0, 0, 1, 1)
            canvas.display = d
            canvas.cropAspect = nil
        }
        ImageStore.shared.replace(turned, for: turned.url)
        sourceStats = turned.sourceStats
        canvas.replaceImage(turned)
        scopes.update(with: nil, image: turned)
        recomputeScopes()
        window?.subtitle = subtitleForCurrent()
    }

    /// Decode what you are most likely to ask for next.
    ///
    /// Weighted in the direction you are already travelling — two ahead, one
    /// back — because someone stepping through a folder almost always carries on
    /// the same way, and the one behind is the cheap insurance for changing
    /// their mind. Two ahead is deliberate: over a network share a single file
    /// can take longer to arrive than it takes to look at the one before it.
    private func prefetchNeighbours() {
        guard siblings.count > 1 else { return }
        let ahead = lastNavigationDelta >= 0 ? 1 : -1
        let wanted = [index + ahead, index + 2 * ahead, index - ahead]
            .filter { siblings.indices.contains($0) }
            .map { siblings[$0] }
        ImageStore.shared.prefetch(wanted)
    }

    private func present(_ img: FloatImage) {
        if !hasSizedToImage {
            hasSizedToImage = true
            sizeWindow(to: img)
        }
        sourceStats = img.sourceStats   // measured at load, off the main thread
        canvas.show(img)

        if let session = pendingSession {
            pendingSession = nil
            var d = canvas.display
            session.apply(to: &d)
            canvas.display = d
            canvas.cropAspect = nil
            if let path = session.lutPath, FileManager.default.fileExists(atPath: path) {
                applyLUT(at: URL(fileURLWithPath: path), announceFailure: false)
            } else {
                canvas.clearLUT()
                currentLUTPath = nil
            }
            // Deferred so it lands after the load settles, like a preset does.
            DispatchQueue.main.async { [weak self] in
                self?.refreshLibrary()
                self?.syncPanelControls()
            }
            window?.subtitle = subtitleForCurrent()
            window?.makeFirstResponder(canvas)
            return
        }

        // Every image opens unedited. A grade belongs to the picture it was made
        // for, so carrying one into the next file would quietly show you someone
        // else's photograph — and a viewer's first job is to be trusted about
        // what is in the file.
        //
        // The diagnostic overlays are not edits and do survive: if you were
        // looking at the blue channel, you were doing that on purpose and are
        // probably still doing it.
        var fresh = Renderer.DisplayState()
        fresh.channel = canvas.display.channel
        fresh.showClipping = canvas.display.showClipping
        fresh.falseColour = canvas.display.falseColour
        // The view transform is not a grade — it is how a file of this kind has
        // to be rendered to be correct at all.
        fresh.viewTransform = Preferences.viewTransform(sceneLinear: img.isSceneLinear)
        // Nor is this: it says how a LUT should be *read*, and your LUTs keep
        // coming from the same camera. Inert until you actually load one.
        fresh.lutInput = LUTInput(rawValue: Preferences.lutInput) ?? .display
        canvas.display = fresh
        canvas.clearLUT()
        canvas.cropAspect = nil
        currentLUTPath = nil
        currentPresetName = nil

        refreshLibrary()
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
                       downsampled: c.isDownsampledView,
                       backdrop: c.isAdjustingBackground ? Theme.backgroundSRGB : nil)
    }

    func canvasDisplayChanged(_ c: ImageCanvasView) {
        syncPanelControls()
        // Every change to how the image is rendered invalidates the scopes, so
        // there is one hook rather than a call beside each control.
        recomputeScopes()
    }

    /// The backdrop is one colour for the whole window, so a change to it has to
    /// reach the chrome as well as the canvas.
    func canvasDidChangeBackground(_ c: ImageCanvasView) {
        applyBackgroundEverywhere()
        canvasReadoutChanged(c)
    }

    /// One backdrop for the whole window: the chrome, both panels, the footer and
    /// every label re-derive from the same number, so nothing is left behind at a
    /// colour that no longer matches.
    private func applyBackgroundEverywhere() {
        // Control chrome is the one thing AppKit gives no continuum for — a
        // segmented control is either its light or its dark rendering — so this
        // stays a switch, confined to controls.
        window?.appearance = Theme.appearance
        window?.backgroundColor = Theme.background
        window?.contentView?.layer?.backgroundColor = Theme.background.cgColor
        scopes.refreshBackground()
        grade.refreshBackground()
        readout.refreshBackground()
        gradeButton.image = Theme.gradeIcon(active: gradeOpen)
        scopesButton.contentTintColor = scopesOpen ? Theme.text(.primary) : Theme.text(.tertiary)
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
        lastNavigationDelta = delta
        index = (index + delta + siblings.count) % siblings.count
        loadCurrent()
    }

    // MARK: - Sessions

    /// Where this window's work came from, so Save can offer to overwrite it.
    private var sessionURL: URL?

    @objc func saveSession(_ sender: Any?) {
        guard let img = canvas.image else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(Session.typeIdentifier)
            ?? UTType(filenameExtension: Session.fileExtension) ?? .json]
        panel.nameFieldStringValue =
            (sessionURL?.deletingPathExtension().lastPathComponent
             ?? img.url.deletingPathExtension().lastPathComponent)
            + "." + Session.fileExtension
        panel.message = "Saves what you've done, and which image you did it to. The image itself isn't copied."
        guard panel.runModal() == .OK, let out = panel.url else { return }

        let session = Session.from(canvas.display, image: img.url, lutPath: currentLUTPath)
        do {
            try session.write(to: out)
            sessionURL = out
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn’t save the session"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    /// Restores a session into this window: the image it names, then every value.
    func open(session url: URL) {
        var session: Session
        do { session = try Session.read(from: url) } catch {
            let a = NSAlert()
            a.messageText = "Couldn’t read that session"
            a.informativeText = error.localizedDescription
            a.runModal()
            return
        }

        let imageURL: URL
        switch session.resolveImage() {
        case .found(let u):
            imageURL = u
        case .moved(let u):
            // The bookmark exists precisely so a moved file is not an event: use
            // what it found and carry on. The file on disk is left exactly as it
            // was — a session is only ever written when you ask for one.
            imageURL = u
        case .missing(let path):
            guard let located = askToLocate(missing: path) else { return }
            imageURL = located
            // Written back, because you just chose this file: the session is
            // already open and broken, and repairing it is the point of having
            // been asked. Distinct from the moved case above, which resolves on
            // its own and so has no choice of yours to act on.
            session.relocate(to: located)
            try? session.write(to: url)
        }

        // Remembered only so Save Session offers to overwrite the same file.
        sessionURL = url
        pendingSession = session
        hasSizedToImage = true      // the window is the user's, not the session's
        open(url: imageURL)
    }

    /// Offer to go and find an image the session can no longer see.
    ///
    /// A session that only reports the problem makes you repair it by hand in a
    /// text editor; one that lets you point at the file turns a dead end into two
    /// clicks. What you pick is written back, since a broken session that stays
    /// broken would ask again every time — and unlike a move the bookmark can
    /// resolve on its own, there is an explicit choice of yours to record.
    private func askToLocate(missing path: String) -> URL? {
        let name = (path as NSString).lastPathComponent
        let a = NSAlert()
        a.messageText = "Can’t find “\(name)”"
        a.informativeText = "This session refers to an image at:\n\(path)\n\nA session records where an image lives rather than embedding it. Point Lupp at the file and the session will be updated to match, so it only has to ask once."
        a.addButton(withTitle: "Find…")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return nil }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ImageLoader.readableTypes.compactMap { UTType($0) }
        panel.message = "Find “\(name)”"
        panel.nameFieldStringValue = name
        // Start where it used to be, since a moved file is often still nearby.
        let oldDir = (path as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: oldDir) {
            panel.directoryURL = URL(fileURLWithPath: oldDir)
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: - Export

    /// Writes what is on screen: same shader, same settings, full resolution.
    @objc func exportImage(_ sender: Any?) {
        guard let img = canvas.image else { NSSound.beep(); return }
        let panel = NSSavePanel()
        let initial = ExportFormatAccessory.Format.from(
            extension: Preferences.lastExportExtension)
        panel.nameFieldStringValue =
            img.url.deletingPathExtension().lastPathComponent + "-lupp." + initial.ext
        panel.message = "Export the image as displayed — view transform, grade, LUT and exposure baked in."
        let accessory = ExportFormatAccessory(panel: panel, initial: initial)
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let out = panel.url else { return }
        // Whatever the field ends up saying wins, in case it was typed by hand.
        let format = ExportFormatAccessory.Format.from(extension: out.pathExtension)
        Preferences.lastExportExtension = format.ext

        guard let cg = canvas.exportImage(bitDepth: format.bitDepth),
              let dest = CGImageDestinationCreateWithURL(
                  out as CFURL, format.type.identifier as CFString, 1, nil)
        else {
            let a = NSAlert()
            a.messageText = "Couldn’t export"
            a.informativeText = "Rendering the image for export failed."
            a.runModal()
            return
        }
        var props: [CFString: Any] = [:]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }
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

extension ViewerWindowController: NSMenuItemValidation {
    /// Keep bare-key shortcuts out of the way of typing.
    ///
    /// M, N, Home and End all mean something in a text field, and a menu item
    /// with no modifier would normally consume the key before the field editor
    /// ever saw it. Returning false while text is being edited both greys the
    /// item out and lets the keystroke carry on down the responder chain, which
    /// is what someone halfway through typing a number expects.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if !item.keyEquivalent.isEmpty, item.keyEquivalentModifierMask.isEmpty,
           window?.firstResponder is NSText {
            return false
        }
        return true
    }
}
