import AppKit
import MetalKit
import simd

protocol ImageCanvasDelegate: AnyObject {
    func canvasReadoutChanged(_ canvas: ImageCanvasView)
    func canvasDisplayChanged(_ canvas: ImageCanvasView)
    func canvasWantsNavigation(_ canvas: ImageCanvasView, by delta: Int)
    func canvas(_ canvas: ImageCanvasView, wantsToOpen urls: [URL])
    func canvasDidChangeBackground(_ canvas: ImageCanvasView)
}

/// The image surface: zoom, pan, and the eyedropper.
final class ImageCanvasView: MTKView {
    weak var canvasDelegate: ImageCanvasDelegate?

    private var renderer: Renderer?
    let cropOverlay = CropOverlayView()
    private(set) var image: FloatImage?
    private var viewport = Viewport()

    /// Everything that changes how the image is shown but not what it contains.
    /// The readout always reports the file's own values, never the displayed
    /// ones — otherwise the numbers would describe a viewing decision rather
    /// than the image.
    var display = Renderer.DisplayState() {
        didSet {
            needsDisplay = true
            // The overlay is for placing a crop; once applied there is nothing
            // left outside it to show.
            cropOverlay.isHidden = !display.cropEnabled || display.cropApplied
            if oldValue.cropApplied != display.cropApplied
                || oldValue.cropEnabled != display.cropEnabled {
                needsInitialFit = true
                applyInitialFitIfNeeded()
                viewport.clamp(viewSize: bounds.size, imageSize: imageSize)
            }
            if cropOverlay.crop != display.crop { cropOverlay.crop = display.crop }
            canvasDelegate?.canvasReadoutChanged(self)
            canvasDelegate?.canvasDisplayChanged(self)
        }
    }

    /// Where the image quad currently sits in view coordinates. The crop overlay
    /// needs this to place itself; nothing else outside the canvas does.
    var imageViewRect: CGRect {
        guard image != nil else { return .zero }
        return CGRect(x: viewport.origin.x, y: viewport.origin.y,
                      width: imageSize.width * viewport.scale,
                      height: imageSize.height * viewport.scale)
    }

    var exposureEV: Float {
        get { display.exposureEV }
        set { display.exposureEV = newValue }
    }

    private(set) var cursorPixel: (x: Int, y: Int)?
    private(set) var cursorValue: SIMD4<Float>?

    private var spaceHeld = false
    private var panning = false
    private var trackingAreaRef: NSTrackingArea?

    /// Zoom is chosen once, when the image first appears, and after that only by
    /// an explicit zoom command.
    ///
    /// Resizing the window deliberately does *not* re-fit: the window is a
    /// viewport that moves over the image, so dragging its edge should reveal more
    /// of the picture at the same magnification rather than silently rescaling
    /// what you were inspecting.
    ///
    /// The flag exists because `show()` can run before Auto Layout has given the
    /// canvas its real bounds — the fit is applied at the first layout that has
    /// them, then never again.
    private var needsInitialFit = false

    /// Scale at which one image pixel covers exactly one physical display pixel.
    private var oneToOne: CGFloat { 1 / max(window?.backingScaleFactor ?? 1, 1) }

    var zoomPercent: Double { Double(viewport.scale / oneToOne) * 100 }
    var isDownsampledView: Bool { image?.wasDownsampled ?? false }

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true

        // The surround is chrome, not image, so it is left to the window's own
        // background rather than painted by Metal's clear colour.
        //
        // Painting it here made it update on a different clock from everything
        // else: CALayer colours change within the current runloop pass, while a
        // Metal clear colour only lands when the GPU next presents, so during a
        // backdrop drag the canvas visibly trailed the panels around it. A
        // transparent drawable puts both on the same clock.
        (layer as? CAMetalLayer)?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        // A still image has no reason to redraw at 120 Hz. Draw on demand only —
        // this is most of what "lightweight" means in practice.
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true

        renderer = Renderer(pixelFormat: colorPixelFormat)
        registerForDraggedTypes([.fileURL])

        cropOverlay.imageRectProvider = { [weak self] in self?.imageViewRect ?? .zero }
        cropOverlay.imagePixelSize = { [weak self] in
            guard let i = self?.image else { return .zero }
            return CGSize(width: i.width, height: i.height)
        }
        cropOverlay.loupeProvider = { [weak self] point, src, out in
            self?.loupe(aroundImagePoint: point, sourcePixels: src, output: out)
        }
        cropOverlay.onChange = { [weak self] c in
            guard let self else { return }
            self.display.crop = c
        }
        cropOverlay.isHidden = true
        cropOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cropOverlay)
        NSLayoutConstraint.activate([
            cropOverlay.topAnchor.constraint(equalTo: topAnchor),
            cropOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            cropOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            cropOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Drag and drop

    private var dragHighlight = false { didSet { needsDisplay = true } }

    private func imageURLs(from sender: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: opts) as? [URL] ?? []
        return urls.filter(ImageLoader.canRead)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !imageURLs(from: sender).isEmpty
        dragHighlight = ok
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dragHighlight = false }

    override func draggingEnded(_ sender: NSDraggingInfo) { dragHighlight = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragHighlight = false
        let urls = imageURLs(from: sender)
        guard !urls.isEmpty else { return false }
        canvasDelegate?.canvas(self, wantsToOpen: urls)
        return true
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    /// Transparent outside the image quad, so the window's background is what
    /// fills the surround.
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Content

    func loadLUT(_ lut: CubeLUT) -> Bool {
        let ok = renderer?.loadLUT(lut) ?? false
        needsDisplay = true
        return ok
    }

    /// Ratio the crop is locked to, in pixels; nil is free.
    var cropAspect: Double? {
        get { cropOverlay.aspect }
        set { cropOverlay.aspect = newValue }
    }

    /// A small graded render for the scopes to measure — same shader as the
    /// screen, so the traces and the picture always agree.
    func renderSampled(maxDimension: Int) -> (data: [Float], width: Int, height: Int)? {
        guard image != nil else { return nil }
        return renderer?.renderSampled(display: display, maxDimension: maxDimension)
    }

    /// A magnified, graded patch of the source around a point, for the crop loupe.
    func loupe(aroundImagePoint p: CGPoint, sourcePixels: Int, output: Int) -> CGImage? {
        guard let i = image else { return nil }
        let halfU = Float(sourcePixels) / Float(i.width) / 2
        let halfV = Float(sourcePixels) / Float(i.height) / 2
        let u = Float(p.x) / Float(i.width), v = Float(p.y) / Float(i.height)
        return renderer?.renderWindow(uv: SIMD4(u - halfU, v - halfV, u + halfU, v + halfV),
                                      width: output, height: output, display: display)
    }

    /// The exported pixels come from the same shader as the screen's.
    func exportImage(bitDepth: Int) -> CGImage? {
        guard let img = image else { return nil }
        return renderer?.exportImage(size: CGSize(width: img.width, height: img.height),
                                     display: display, bitDepth: bitDepth)
    }

    func clearLUT() {
        renderer?.clearLUT()
        display.lutName = nil
        needsDisplay = true
    }

    func show(_ img: FloatImage?) {
        image = img
        if let img {
            renderer?.upload(img)
            needsInitialFit = true
            applyInitialFitIfNeeded()
        } else {
            renderer?.discard()
        }
        cursorPixel = nil
        cursorValue = nil
        exposureEV = 0
        needsDisplay = true
        canvasDelegate?.canvasReadoutChanged(self)
    }

    /// Swap the pixels without disturbing how they are being shown.
    ///
    /// Turning an image is a correction to how the file was read, not an edit,
    /// so the grade you have built survives it — unlike `show`, which is for
    /// arriving at a new picture. The fit is redone because the aspect has
    /// changed and the old zoom would leave you looking at the wrong part.
    func replaceImage(_ img: FloatImage) {
        image = img
        renderer?.upload(img)
        needsInitialFit = true
        applyInitialFitIfNeeded()
        cursorPixel = nil
        cursorValue = nil
        needsDisplay = true
        canvasDelegate?.canvasReadoutChanged(self)
    }

    /// The size the viewport works in: the crop once it has been applied,
    /// otherwise the whole image. Zoom, fit and the readout all follow from this,
    /// so applying a crop makes the app treat it as the picture.
    private var imageSize: CGSize {
        guard let i = image else { return .zero }
        let c = display.cropPixels(imageWidth: i.width, imageHeight: i.height)
        return display.cropApplied && display.cropEnabled
            ? CGSize(width: c.w, height: c.h)
            : CGSize(width: i.width, height: i.height)
    }

    /// Offset from the working image's origin to the source's, in source pixels.
    private var cropOrigin: (x: Int, y: Int) {
        guard let i = image, display.cropApplied, display.cropEnabled else { return (0, 0) }
        let c = display.cropPixels(imageWidth: i.width, imageHeight: i.height)
        return (c.x, c.y)
    }

    // MARK: - Zoom commands

    /// The fit applied when an image opens: 1:1 when it already fits, scaled down
    /// when it doesn't, never enlarged.
    private func applyInitialFitIfNeeded() {
        guard needsInitialFit, image != nil,
              bounds.width > 1, bounds.height > 1 else { return }
        needsInitialFit = false
        viewport = Viewport.initial(viewSize: bounds.size, imageSize: imageSize,
                                    oneToOne: oneToOne)
    }

    /// Explicit "Zoom to Fit" is allowed to enlarge — that is what was asked for.
    /// The automatic fit on open is not.
    func zoomToFit() {
        guard image != nil else { return }
        needsInitialFit = false
        viewport.scale = Viewport.fitScale(viewSize: bounds.size, imageSize: imageSize)
        viewport.clamp(viewSize: bounds.size, imageSize: imageSize)
        refresh()
    }

    func zoomToActualSize() {
        guard image != nil else { return }
        needsInitialFit = false
        viewport.zoom(to: oneToOne, anchor: CGPoint(x: bounds.midX, y: bounds.midY))
        viewport.clamp(viewSize: bounds.size, imageSize: imageSize)
        refresh()
    }

    func zoomStep(_ factor: CGFloat, anchor: CGPoint? = nil) {
        guard image != nil else { return }
        needsInitialFit = false
        viewport.zoom(to: viewport.scale * factor,
                      anchor: anchor ?? CGPoint(x: bounds.midX, y: bounds.midY))
        viewport.clamp(viewSize: bounds.size, imageSize: imageSize)
        refresh()
    }

    private func refresh() {
        needsDisplay = true
        cropOverlay.needsDisplay = true
        window?.invalidateCursorRects(for: cropOverlay)
        updateReadout(at: window?.mouseLocationOutsideOfEventStream)
    }

    // MARK: - Input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited,
                                         .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    /// Mouse wheel zooms; trackpad two-finger scroll pans.
    ///
    /// Told apart by gesture *phase*, not by `hasPreciseScrollingDeltas`. Smooth
    /// scrolling drivers — Logi Options+ among them — make an ordinary wheel report
    /// precise deltas, so the obvious check silently classifies those mice as
    /// trackpads and pans when the user asked to zoom. Only a real trackpad reports
    /// began/changed/ended phases.
    override func scrollWheel(with e: NSEvent) {
        guard image != nil else { return }

        let isTrackpad = e.phase != [] || e.momentumPhase != []
        var wantsZoom = isTrackpad ? false : Preferences.scrollWheelZooms
        if e.modifierFlags.contains(.option) { wantsZoom.toggle() }
        Preferences.logScroll(e, isTrackpad: isTrackpad, zooming: wantsZoom)

        if wantsZoom {
            // Precise deltas arrive in pixels and a notched wheel in lines; scale
            // them to a common unit so one wheel click isn't a 3× jump.
            var unit = e.scrollingDeltaY
            if e.hasPreciseScrollingDeltas { unit /= 8 }
            // Undo the natural-scroll inversion to recover the physical wheel
            // direction. Panning should follow that preference — it is scrolling.
            // Zooming should not: wheel-forward means zoom in everywhere else.
            if e.isDirectionInvertedFromDevice { unit = -unit }
            if Preferences.invertScrollZoom { unit = -unit }
            guard unit != 0 else { return }
            zoomStep(pow(1.12, max(-3, min(3, unit))),
                     anchor: convert(e.locationInWindow, from: nil))
        } else {
            guard e.scrollingDeltaX != 0 || e.scrollingDeltaY != 0 else { return }
            viewport.pan(by: CGSize(width: e.scrollingDeltaX, height: e.scrollingDeltaY))
            viewport.clamp(viewSize: bounds.size, imageSize: imageSize)
            refresh()
        }
    }

    override func magnify(with e: NSEvent) {
        guard image != nil else { return }
        zoomStep(1 + e.magnification, anchor: convert(e.locationInWindow, from: nil))
    }

    // Middle mouse button. Note macOS Mouse settings often bind button 3 to
    // Mission Control, which eats the event before it reaches us — hence the
    // space-drag fallback below, which also covers trackpads.
    override func otherMouseDown(with e: NSEvent) {
        guard e.buttonNumber == 2 else { return }
        beginPan()
    }

    override func otherMouseDragged(with e: NSEvent) {
        guard panning else { return }
        dragPan(e)
    }

    override func otherMouseUp(with e: NSEvent) { endPan() }

    // Left-drag pans. Middle-click still works where the OS lets it through, but
    // it can't be the primary gesture: macOS Mouse settings routinely bind
    // button 3 to Mission Control, and trackpads have no middle button at all.
    override func mouseDown(with e: NSEvent) {
        // Clicking the picture takes the keyboard back. AppKit does not move
        // first responder on a click by itself, so after typing in a panel field
        // the field editor keeps it — and every bare-key shortcut stays dead
        // until you notice why.
        window?.makeFirstResponder(self)
        beginPan()
    }

    override func mouseDragged(with e: NSEvent) {
        if panning { dragPan(e) } else { updateReadout(at: e.locationInWindow) }
    }

    override func mouseUp(with e: NSEvent) { endPan() }

    // Right-drag sets the backdrop. Right-click has no menu here to compete with,
    // and judging an image against the wrong surround is a real problem — a bright
    // one makes a dark frame look washed out — so it deserves a gesture rather
    // than a trip to a preferences pane.
    private var backgroundDragStart: (y: CGFloat, level: CGFloat)?

    override func rightMouseDown(with e: NSEvent) {
        backgroundDragStart = (e.locationInWindow.y, Theme.backgroundSRGB)
    }

    override func rightMouseDragged(with e: NSEvent) {
        guard let start = backgroundDragStart else { return }
        // Up is lighter. 300pt of travel covers the whole usable range, which is
        // enough to be precise without needing the whole screen.
        let delta = (e.locationInWindow.y - start.y) / 300
        Theme.backgroundSRGB = start.level + delta
        applyBackground()
        canvasDelegate?.canvasDidChangeBackground(self)
    }

    override func rightMouseUp(with e: NSEvent) { backgroundDragStart = nil }

    /// True while the backdrop is being dragged, so the readout can show its value.
    var isAdjustingBackground: Bool { backgroundDragStart != nil }

    /// Nothing to repaint here any more — the surround belongs to the window's
    /// background layer, which the controller updates with the rest of the chrome.
    func applyBackground() {
        needsDisplay = true
    }

    override func mouseMoved(with e: NSEvent) {
        updateReadout(at: e.locationInWindow)
    }

    override func mouseExited(with e: NSEvent) {
        cursorPixel = nil
        cursorValue = nil
        canvasDelegate?.canvasReadoutChanged(self)
    }

    private func beginPan() {
        panning = true
        NSCursor.closedHand.push()
    }

    private func dragPan(_ e: NSEvent) {
        viewport.pan(by: CGSize(width: e.deltaX, height: e.deltaY))
        viewport.clamp(viewSize: bounds.size, imageSize: imageSize)
        needsDisplay = true
        cropOverlay.needsDisplay = true
    }

    private func endPan() {
        guard panning else { return }
        panning = false
        NSCursor.pop()
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 49 {                       // space
            if !spaceHeld { spaceHeld = true; NSCursor.openHand.push() }
            return
        }
        switch e.charactersIgnoringModifiers {
        case String(UnicodeScalar(NSRightArrowFunctionKey)!),
             String(UnicodeScalar(NSDownArrowFunctionKey)!):
            canvasDelegate?.canvasWantsNavigation(self, by: 1)
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!),
             String(UnicodeScalar(NSUpArrowFunctionKey)!):
            canvasDelegate?.canvasWantsNavigation(self, by: -1)
        case "e": exposureEV += 0.25
        case "E": exposureEV -= 0.25
        case "r": exposureEV = 0
        case "b": display.gradeEnabled.toggle()
        case "c": display.showClipping.toggle()
        case "f": display.falseColour.toggle()
        // M and N are the View menu's own key equivalents, so they never reach
        // here — the menu is where the shortcut is written down, and one owner
        // is better than two that can disagree.
        case "1": display.channel = .rgb
        case "2": display.channel = .red
        case "3": display.channel = .green
        case "4": display.channel = .blue
        case "5": display.channel = .alpha
        case "6": display.channel = .luma
        default: super.keyDown(with: e)
        }
    }

    override func keyUp(with e: NSEvent) {
        if e.keyCode == 49, spaceHeld {
            spaceHeld = false
            if !panning { NSCursor.pop() }
        }
    }

    // MARK: - Readout

    private func updateReadout(at windowPoint: CGPoint?) {
        guard let img = image, let wp = windowPoint else { return }
        let p = convert(wp, from: nil)
        let ip = viewport.imagePoint(fromView: p)
        // Report source coordinates even when a crop is applied — the numbers
        // should say where the pixel is in the file, not in the current view of it.
        let o = cropOrigin
        let x = Int(floor(ip.x)) + o.x, y = Int(floor(ip.y)) + o.y
        if let v = img.sample(x: x, y: y) {
            cursorPixel = (x, y)
            cursorValue = v
        } else {
            cursorPixel = nil
            cursorValue = nil
        }
        canvasDelegate?.canvasReadoutChanged(self)
    }

    // MARK: - Draw

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard image != nil else { needsDisplay = true; return }
        // Only the first layout may set the zoom. Every resize after that leaves
        // the magnification alone and just re-clamps, so the window pans over the
        // image instead of rescaling it.
        applyInitialFitIfNeeded()
        viewport.clamp(viewSize: bounds.size, imageSize: imageSize)
        needsDisplay = true
        cropOverlay.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        renderer?.draw(in: self, viewport: viewport, display: display,
                       dragHighlight: dragHighlight,
                       backingScale: window?.backingScaleFactor ?? 1)
    }
}
