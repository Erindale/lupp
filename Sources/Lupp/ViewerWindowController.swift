import AppKit

/// One window, one image, plus its folder for arrow-key navigation.
final class ViewerWindowController: NSWindowController, ImageCanvasDelegate, NSWindowDelegate {
    private let canvas = ImageCanvasView()
    private let readout = ReadoutBar()
    private let scopes = ScopesPanel()
    private var scopesWidth: NSLayoutConstraint!
    private let scopesButton = NSButton()

    private var siblings: [URL] = []
    private var index = 0
    /// Bumped on every load so a slow decode that lands after you've arrowed
    /// past it gets dropped instead of overwriting the image you're now on.
    private var loadToken = 0
    private var scopesToken = 0
    private var hasSizedToImage = false

    private var scopesOpen: Bool {
        get { Preferences.scopesPanelOpen }
        set { Preferences.scopesPanelOpen = newValue }
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

        // Restores the last size and position. Only the very first window ever
        // opened sizes itself to the image; after that the window you chose wins
        // and the image scales to fit it.
        hasSizedToImage = Preferences.hasSavedWindowFrame
        window.setFrameAutosaveName(Preferences.windowFrameAutosaveName)
        if !hasSizedToImage { window.center() }
        else if let last = AppDelegate.shared?.frontmostViewerFrame, last == window.frame {
            window.setFrameOrigin(NSPoint(x: last.minX + 24, y: last.minY - 24))
        }
        applyScopesVisibility(animated: false)
        open(url: url)
    }

    private func buildContentView() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.background.cgColor

        for v in [canvas, scopes, readout] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        scopesWidth = scopes.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: scopes.leadingAnchor),
            canvas.bottomAnchor.constraint(equalTo: readout.topAnchor),

            scopes.topAnchor.constraint(equalTo: content.topAnchor),
            scopes.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scopes.bottomAnchor.constraint(equalTo: readout.topAnchor),
            scopesWidth,

            readout.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            readout.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            readout.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            readout.heightAnchor.constraint(equalToConstant: ReadoutBar.height),
        ])
    }

    /// The scopes toggle lives in the title bar's right-hand accessory slot, which
    /// is how AppKit puts a control up there without a custom title bar.
    private func buildTitlebarAccessory() {
        scopesButton.bezelStyle = .texturedRounded
        scopesButton.isBordered = false
        scopesButton.image = NSImage(systemSymbolName: "chart.bar.xaxis",
                                     accessibilityDescription: "Scopes")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        scopesButton.imagePosition = .imageOnly
        scopesButton.target = self
        scopesButton.action = #selector(toggleScopes(_:))
        scopesButton.toolTip = "Scopes — histogram, RGB parade, vectorscope"
        scopesButton.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 42, height: 28))
        host.addSubview(scopesButton)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 42),
            host.heightAnchor.constraint(equalToConstant: 28),
            scopesButton.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            scopesButton.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
        ])

        let acc = NSTitlebarAccessoryViewController()
        acc.layoutAttribute = .right
        acc.view = host
        window?.addTitlebarAccessoryViewController(acc)
    }

    // MARK: - Scopes

    @objc func toggleScopes(_ sender: Any?) {
        scopesOpen.toggle()
        applyScopesVisibility(animated: true)
    }

    private func applyScopesVisibility(animated: Bool) {
        let target: CGFloat = scopesOpen ? Theme.panelWidth : 0
        // Grey when closed, white when open — the accent colour read as an alert
        // rather than as a state, which is not what a view toggle should say.
        scopesButton.contentTintColor = scopesOpen ? .labelColor : .secondaryLabelColor
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.allowsImplicitAnimation = true
                scopesWidth.animator().constant = target
                window?.contentView?.layoutSubtreeIfNeeded()
            }
        } else {
            scopesWidth.constant = target
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
        recomputeScopes()

        var subtitle = "\(img.fullWidth) × \(img.fullHeight)"
        subtitle += " · \(shortType(img.typeIdentifier)) \(img.sourceBitDepth)-bit"
        subtitle += " · \(img.sourceColorSpace)"
        if img.isHDR { subtitle += " · HDR to \(String(format: "%.2f", img.maxComponent))" }
        if siblings.count > 1 { subtitle += "  ·  \(index + 1) of \(siblings.count)" }
        window?.subtitle = subtitle
        window?.makeFirstResponder(canvas)
    }

    private func sizeWindow(to img: FloatImage) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let avail = screen.visibleFrame.insetBy(dx: 60, dy: 60)
        let native = CGSize(width: CGFloat(img.width) / max(screen.backingScaleFactor, 1),
                            height: CGFloat(img.height) / max(screen.backingScaleFactor, 1))
        let chrome = scopesOpen ? Theme.panelWidth : 0
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

    func canvasWantsNavigation(_ c: ImageCanvasView, by delta: Int) {
        guard siblings.count > 1 else { return }
        index = (index + delta + siblings.count) % siblings.count
        loadCurrent()
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

    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared?.forget(self)
    }
}
