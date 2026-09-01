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
    /// Where a backdrop drag started, and what the level was when it did.
    ///
    /// Handled at the window because the gesture is about the whole interface,
    /// not about the picture — judging an image against the wrong surround is a
    /// real problem, and having to find the canvas first would be a silly
    /// condition to put on fixing it. Right-drag over a panel, the footer or the
    /// image and it behaves the same.
    private var backdropDrag: (y: CGFloat, level: CGFloat)?

    /// True while a drag is in progress, so the readout can show the value.
    var isAdjustingBackdrop: Bool { backdropDrag != nil }

    /// Told when the backdrop moves, so the chrome can be repainted.
    var onBackdropChange: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown:
            backdropDrag = (event.locationInWindow.y, Theme.backgroundSRGB)
        case .rightMouseDragged:
            if let start = backdropDrag {
                // Up is lighter. 300pt of travel covers the whole usable range,
                // which is enough to be precise without needing the whole screen.
                Theme.backgroundSRGB = start.level + (event.locationInWindow.y - start.y) / 300
                onBackdropChange?()
                return          // the panels' own controls must not also see this
            }
        case .rightMouseUp:
            if backdropDrag != nil { backdropDrag = nil; return }
        default:
            break
        }

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
    /// Whether that pending work came from this window's own cache rather than
    /// from a `.lupp` file. A saved session records how you were looking at the
    /// image as well as what you did to it; work you are simply scrolling back
    /// past should not reach up and change which channel you are inspecting.
    private var pendingIsCachedEdit = false

    /// Every image in this window that you have actually edited, and what you did
    /// to it.
    ///
    /// Each picture keeps its own work, so scrolling a folder shows your grades
    /// rather than one grade imposed on everything — and two frames you graded
    /// differently can be compared by arrowing between them, which a single
    /// carried-forward grade could never do. Copying a look onto the next image
    /// stays a deliberate act: Apply Last, or a preset.
    ///
    /// In memory and for this window only. Nothing here is written to disk;
    /// sessions are still saved when you ask and not before.
    private var edits: [URL: Session] = [:]

    /// What was last *written out* for each image — saved as a session, or
    /// exported.
    ///
    /// This is what makes "unsaved" mean something. Lupp is non-destructive and
    /// writes nothing unless asked, so almost every window has edits in it;
    /// warning about all of them would be a dialog you learn to dismiss without
    /// reading. Comparing against what actually reached disk means the warning
    /// fires when work would genuinely be lost, and stays quiet when it would
    /// not — including when you exported an image and then changed nothing.
    private var committed: [URL: Session] = [:]
    /// Held while a batch runs, so the sheet is not released mid-export.
    private var bulkSheet: BulkExportSheet?
    private var lutSheet: LUTBakeSheet?

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

    /// A window with nothing open in it yet.
    ///
    /// Launching the app on its own used to put an open panel in front of you
    /// before you had seen the app at all. A window that says what it is waiting
    /// for is a gentler door, and it is also the one you land on after a load
    /// fails, so the state had to exist regardless.
    convenience init() {
        self.init(url: nil, deferOpening: true)
        window?.title = "Lupp"
        window?.subtitle = ""
        canvas.show(nil)
    }

    /// Nothing open yet, so this window is available to be filled.
    var hasNoImage: Bool { canvas.image == nil }

    /// Everything needed to build this window again: which picture, and the work
    /// standing on it. Used when the interface size changes, since the panels
    /// size themselves as they are built and there is no honest way to restretch
    /// them in place.
    func rebuildSnapshot() -> (session: Session, image: URL)? {
        guard let img = canvas.image else { return nil }
        return (Session.from(canvas.display, image: img.url,
                             lutPath: currentLUTPath, bookmark: false), img.url)
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

    private convenience init(url: URL?, deferOpening: Bool) {
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
        canvas.onOpenRecent = { [weak self] url in self?.open(url: url) }
        // Where the keyboard goes when nothing else has claimed it — after a
        // field is finished with, and at the start.
        window.initialFirstResponder = canvas
        window.onBackdropChange = { [weak self] in
            guard let self else { return }
            self.applyBackgroundEverywhere()
            // The footer reports the level while the drag is happening, so the
            // gesture isn't blind.
            self.canvasReadoutChanged(self.canvas)
        }
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
        if let url, !deferOpening { open(url: url) }
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
        grade.onBulkExport = { [weak self] in self?.bulkExport() }
        grade.onExportLUT = { [weak self] in self?.exportGradeAsLUT() }
        grade.onEditBegan = { [weak self] in self?.beginEdit() }
        grade.onEditEnded = { [weak self] in self?.endEdit() }
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
            case .saturation:   d.saturationOn = on
            case .lut:          d.lutOn = on
            case .crop:         d.cropEnabled = on
            }
            self.canvas.display = d
        }
        grade.onSaturation = { [weak self] amount in
            guard let self else { return }
            self.canvas.display.saturation = amount
            self.rememberGrade()
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
        grade.setEditedCount(unsavedEditsMap().count)
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

    /// One history per image.
    ///
    /// A single window-wide manager had to be emptied on every navigation, since
    /// undoing back into the grade you had on the previous file would put
    /// someone else's photograph on screen. That made undo useless the moment
    /// you looked at the next frame — and now that each picture keeps its own
    /// edits, its own history is the matching half of the same idea.
    ///
    /// Kept even for an image whose edits were undone back to neutral, so the
    /// reset that got you there is itself undoable.
    private var undoStacks: [URL: UndoManager] = [:]

    /// Far more steps than a sitting on one image plausibly takes, and still a
    /// bound. A grade snapshot is a few hundred bytes, so this is about nothing
    /// growing without limit rather than about size.
    private static let undoDepth = 200

    /// Used only while no image is open, so the Edit menu has something to ask.
    /// Capped like the rest: an unbounded manager nothing much writes to is
    /// still an unbounded manager, and it does accept edits — the colour panel
    /// exists whether or not a picture does.
    private lazy var noImageUndo: UndoManager = {
        let m = UndoManager()
        m.levelsOfUndo = ViewerWindowController.undoDepth
        return m
    }()

    private var undo: UndoManager {
        guard let url = canvas.image?.url else { return noImageUndo }
        if let existing = undoStacks[url] { return existing }
        let made = UndoManager()
        made.levelsOfUndo = ViewerWindowController.undoDepth
        undoStacks[url] = made
        return made
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    // MARK: - Unsaved work

    /// Images whose current state has never reached disk, with the work itself.
    ///
    /// This, rather than every image you have touched, is what "still to do"
    /// means: an image exported and then left alone is finished, and offering to
    /// write it again is offering to redo work and overwrite a file for no gain.
    func unsavedEditsMap() -> [URL: Session] {
        allEdits().filter { url, session in
            committed[url].map(ViewerWindowController.editContent) != editContent(session)
        }
    }

    /// A session reduced to what was actually *done* to the image.
    ///
    /// A Session records how you were looking at it as well as what you changed,
    /// because a saved `.lupp` should reopen the way you left it. None of that is
    /// work: switching to the blue channel or turning on the clipping overlay
    /// after an export made the image count as unsaved again, which inflated
    /// everything measured from that set — the button, the close warning, and the
    /// "already written" number beside the re-export box, which is where it was
    /// most visible because it went *down*.
    static func editContent(_ s: Session) -> Session {
        var n = s
        n.channel = ChannelView.rgb.rawValue
        n.showClipping = false
        n.falseColour = false
        return n
    }

    private func editContent(_ s: Session) -> Session {
        ViewerWindowController.editContent(s)
    }

    func unsavedEdits() -> [URL] {
        unsavedEditsMap().keys.sorted { $0.path < $1.path }
    }

    /// Noted when work reaches disk, so it stops counting as unsaved.
    private func markCommitted(_ url: URL, _ session: Session) {
        committed[url] = session
    }

    /// Asked before a window closes and before the app quits.
    ///
    /// Three ways out rather than two: the useful answer to "you have unsaved
    /// grades" is usually to write them, and having to cancel, find the button
    /// and come back is a chore the dialog can simply remove.
    func confirmDiscardingEdits() -> Bool {
        let unsaved = unsavedEdits()
        guard !unsaved.isEmpty else { return true }

        let a = NSAlert()
        a.messageText = unsaved.count == 1
            ? "One image has edits that haven’t been saved or exported"
            : "\(unsaved.count) images have edits that haven’t been saved or exported"
        a.informativeText = unsaved.prefix(6).map { $0.lastPathComponent }
            .joined(separator: "\n")
            + (unsaved.count > 6 ? "\n…and \(unsaved.count - 6) more" : "")
            + "\n\nYour source files are untouched either way — it’s the grades that would go."
        a.addButton(withTitle: "Export All Edited…")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Discard")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            // Stay open and put the batch dialog up; closing again afterwards
            // will find nothing left to warn about.
            DispatchQueue.main.async { [weak self] in self?.bulkExport() }
            return false
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmDiscardingEdits()
    }

    // MARK: - Grade as a LUT

    /// The menu's way in. Same action as the panel button, so the two cannot
    /// come to mean different things.
    @objc func exportGradeAsLUTMenu(_ sender: Any?) { exportGradeAsLUT() }

    private func exportGradeAsLUT() {
        guard let window else { return }
        guard hasEdits(canvas.display, lutPath: currentLUTPath) else {
            let a = NSAlert()
            a.messageText = "There’s no grade to write out"
            a.informativeText = "Adjust something first — an identity LUT is a large file that does nothing."
            a.runModal()
            return
        }
        let stem = canvas.image?.url.deletingPathExtension().lastPathComponent ?? "Lupp Grade"
        let sheet = LUTBakeSheet(
            suggestedName: currentPresetName ?? stem,
            caveats: LUTBake.caveats(for: canvas.display, sceneLinear: currentIsSceneLinear))
        lutSheet = sheet
        sheet.present(over: window) { [weak self] options in
            self?.lutSheet = nil
            self?.writeLUT(options)
        }
    }

    private func writeLUT(_ options: LUTBake.Options) {
        guard let text = LUTBake.cube(display: canvas.display,
                                      lutPath: currentLUTPath, options: options) else {
            let a = NSAlert()
            a.messageText = "Couldn’t build the LUT"
            a.informativeText = "Rendering the lattice failed."
            a.runModal()
            return
        }
        let file = options.name
            .replacingOccurrences(of: "/", with: "-") + ".cube"
        var written: [URL] = []
        var failed: String?

        if let folder = options.destination {
            let out = folder.appendingPathComponent(file)
            do { try text.write(to: out, atomically: true, encoding: .utf8); written.append(out) }
            catch { failed = error.localizedDescription }
        }
        if options.addToLibrary {
            // Via a temporary file and the library's own importer, so a baked LUT
            // arrives by exactly the same door as one you added from disk.
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(file)
            if (try? text.write(to: tmp, atomically: true, encoding: .utf8)) != nil {
                written.append(URL(fileURLWithPath: LUTLibrary.add(importing: tmp)))
                try? FileManager.default.removeItem(at: tmp)
                refreshLibrary()
            }
        }

        let a = NSAlert()
        if let failed {
            a.messageText = "Couldn’t write the LUT"
            a.informativeText = failed
        } else {
            a.messageText = "Wrote \(options.name).cube"
            a.informativeText = written.map { $0.deletingLastPathComponent().path }
                .joined(separator: "\n")
        }
        if let first = written.first, failed == nil {
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Show in Finder")
            if a.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([first])
            }
            return
        }
        a.runModal()
    }

    // MARK: - Bulk export

    /// Everything edited in this window, including the picture on screen.
    ///
    /// The cache is written on the way *out* of an image, so the one you are
    /// looking at is not in it yet — and it is the most likely thing you wanted
    /// exported. Folded in here rather than by writing to the cache, so merely
    /// opening the dialog does not record an edit.
    private func allEdits() -> [URL: Session] {
        var all = edits
        if let img = canvas.image, hasEdits(canvas.display, lutPath: currentLUTPath) {
            all[img.url] = Session.from(canvas.display, image: img.url,
                                        lutPath: currentLUTPath, bookmark: false)
        }
        return all
    }

    private func bulkExport() {
        // Only what has not been written. Exporting everything again each time
        // would redo the work and, since nothing is ever overwritten, report a
        // pile of skipped files for its trouble.
        let outstanding = unsavedEditsMap()
        let done = allEdits().count - outstanding.count
        guard !outstanding.isEmpty, let window else {
            let a = NSAlert()
            a.messageText = done > 0
                ? "Everything edited has already been exported"
                : "Nothing has been edited yet"
            a.informativeText = done > 0
                ? "All \(done) edited image\(done == 1 ? " has" : "s have") been written out since it was last changed. Adjust something and it will show up here again."
                : "Grade an image or two first — this writes out every picture in this window that you have changed, each in its own state."
            a.runModal()
            return
        }
        let jobs = outstanding
        let sheet = BulkExportSheet(count: jobs.count, alreadyExported: done,
                                    sample: jobs.keys.sorted { $0.path < $1.path }.first)
        bulkSheet = sheet
        sheet.present(over: window) { [weak self, weak sheet] options, includeDone in
            // Re-exporting the finished ones is a deliberate opt-in, for when the
            // format or the destination is what changed rather than the grade.
            let batch = includeDone ? (self?.allEdits() ?? jobs) : jobs
            BulkExport.run(edits: batch, options: options,
                           progress: { done, total in sheet?.report(done: done, of: total) },
                           finished: { outcome in
                               sheet?.close()
                               self?.bulkSheet = nil
                               // Only what actually landed: a file skipped for
                               // already existing was not written, so the work
                               // it stands for is still unsaved.
                               for (url, session) in batch
                               where outcome.written.contains(
                                   BulkExport.destination(for: url, options: options)) {
                                   self?.markCommitted(url, session)
                               }
                               self?.reportBulk(outcome)
                               // The button counts what is left, so it has to be
                               // told that some of it no longer is.
                               self?.syncPanelControls()
                           })
        }
    }

    private func reportBulk(_ o: BulkExport.Outcome) {
        let a = NSAlert()
        a.messageText = o.failed.isEmpty && o.skipped.isEmpty
            ? "Exported \(o.written.count) image\(o.written.count == 1 ? "" : "s")"
            : "Exported \(o.written.count), with \(o.skipped.count + o.failed.count) left alone"
        var lines: [String] = []
        if !o.skipped.isEmpty {
            // Never silently: a file that already existed is the one case where
            // doing nothing is right and saying nothing is not.
            lines.append("Already existed, so nothing was overwritten:")
            lines += o.skipped.prefix(5).map { "  " + $0.lastPathComponent }
            if o.skipped.count > 5 { lines.append("  …and \(o.skipped.count - 5) more") }
        }
        if !o.failed.isEmpty {
            lines.append("Failed:")
            lines += o.failed.prefix(5).map { "  \($0.0.lastPathComponent) — \($0.1)" }
            if o.failed.count > 5 { lines.append("  …and \(o.failed.count - 5) more") }
        }
        a.informativeText = lines.joined(separator: "\n")
        if let first = o.written.first {
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Show in Finder")
            if a.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([first])
            }
            return
        }
        a.runModal()
    }

    // MARK: - Per-image edits

    /// Whether anything has actually been done to the picture on screen.
    ///
    /// Compared against a neutral state built with *this* image's view transform
    /// and LUT input, because neither is an edit: the transform is chosen from
    /// what kind of file it is, and the input is a standing preference about how
    /// LUTs are read. Measuring against a bare default would file every EXR as
    /// edited the moment it opened.
    private func hasEdits(_ d: Renderer.DisplayState, lutPath: String?) -> Bool {
        var neutral = Renderer.DisplayState()
        neutral.viewTransform = d.viewTransform
        neutral.lutInput = d.lutInput
        var mine = Preset.from(d, lutPath: lutPath); mine.name = ""
        var none = Preset.from(neutral, lutPath: nil); none.name = ""
        // Crop is not part of a preset, so it is asked about separately.
        return mine != none || d.cropEnabled
    }

    /// Called on the way out of an image, while it is still the one on screen.
    private func rememberEditsOnCurrentImage() {
        guard let img = canvas.image else { return }
        if hasEdits(canvas.display, lutPath: currentLUTPath) {
            // No bookmark: this copy never leaves memory, and making one costs a
            // filesystem round trip on every navigation.
            edits[img.url] = Session.from(canvas.display, image: img.url,
                                          lutPath: currentLUTPath, bookmark: false)
        } else {
            // Undone back to neutral: forget it, so the picture is genuinely
            // untouched again rather than carrying an empty record of having
            // once been edited.
            edits.removeValue(forKey: img.url)
        }
    }

    // MARK: - Undo

    /// The grade as it was before the edit in progress.
    ///
    /// Taken once when an edit starts and compared once when it ends, so a
    /// slider drag — which reports a new value every few pixels — is a single
    /// undoable step back to where the drag began, rather than a walk back
    /// through the middle of a movement you made in one go.
    private var editSnapshot: Preset?

    /// Crop is deliberately absent, which is why `Preset` is the unit here and
    /// `Session` is not: a preset carries the whole grade and no crop, so
    /// excluding the crop from undo costs nothing and cannot be forgotten.
    private func currentGrade() -> Preset {
        var p = Preset.from(canvas.display, lutPath: currentLUTPath)
        p.name = ""
        return p
    }

    private func beginEdit() {
        // Nested begins collapse: the outermost one owns the step. A section
        // reset moves several controls, and that is still one edit.
        if editSnapshot == nil { editSnapshot = currentGrade() }
    }

    private func endEdit() {
        guard let before = editSnapshot else { return }
        editSnapshot = nil
        guard before != currentGrade() else { return }   // nothing happened
        registerUndo(restoring: before)
    }

    private func registerUndo(restoring before: Preset) {
        undo.registerUndo(withTarget: self) { target in
            // Redo is the same operation pointed the other way, so registering
            // from inside the undo is what makes the stack work in both
            // directions: the state we are leaving becomes the next step back.
            let redoTo = target.currentGrade()
            target.apply(grade: before)
            target.registerUndo(restoring: redoTo)
        }
        undo.setActionName("Grade Change")
    }

    /// Put a snapshot back without disturbing anything it does not describe —
    /// the crop, the zoom, or which image is open.
    private func apply(grade p: Preset) {
        var d = canvas.display
        p.apply(to: &d)
        canvas.display = d
        if let path = p.lutPath, FileManager.default.fileExists(atPath: path) {
            applyLUT(at: URL(fileURLWithPath: path), announceFailure: false)
        } else {
            canvas.clearLUT()
            currentLUTPath = nil
        }
        rememberGrade()
        DispatchQueue.main.async { [weak self] in
            self?.refreshLibrary()
            self?.syncPanelControls()
        }
        recomputeScopes()
    }

    // MARK: - Loading

    func open(url: URL) {
        Preferences.remember(url)
        siblings = FolderScanner.siblings(of: url)
        index = siblings.firstIndex(of: url) ?? 0
        loadCurrent()
    }

    private func loadCurrent() {
        guard siblings.indices.contains(index) else { return }
        let url = siblings[index]
        rememberEditsOnCurrentImage()
        loadToken += 1
        let token = loadToken

        // Work you already did on this picture, put back. A saved session being
        // opened outranks it — that is an explicit request for a particular state.
        if pendingSession == nil, let cached = edits[url] {
            pendingSession = cached
            pendingIsCachedEdit = true
        }

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
            let cached = pendingIsCachedEdit
            pendingSession = nil
            pendingIsCachedEdit = false
            var d = canvas.display
            // How you are looking at images — which channel, the overlays — is
            // yours and carries across, exactly as it does for an unedited one.
            let looking = (d.channel, d.showClipping, d.falseColour)
            session.apply(to: &d)
            if cached { (d.channel, d.showClipping, d.falseColour) = looking }
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
        // No history to clear: each image has its own, and this one's is
        // whatever it was when you last looked at it. Only the half-finished
        // edit is dropped, since it belonged to the picture you just left.
        editSnapshot = nil

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
                       backdrop: (window as? ViewerWindow)?.isAdjustingBackdrop == true
                           ? Theme.backgroundSRGB : nil)
    }

    func canvasDisplayChanged(_ c: ImageCanvasView) {
        syncPanelControls()
        // Every change to how the image is rendered invalidates the scopes, so
        // there is one hook rather than a call beside each control.
        recomputeScopes()
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
            markCommitted(img.url, Session.from(canvas.display, image: img.url,
                                                lutPath: currentLUTPath, bookmark: false))
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
        markCommitted(img.url, Session.from(canvas.display, image: img.url,
                                            lutPath: currentLUTPath, bookmark: false))
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
        // Where you actually got to, not only where you came in. Arrowing to
        // frame 50 and closing should offer frame 50 next time.
        if let img = canvas.image { Preferences.remember(img.url) }
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
