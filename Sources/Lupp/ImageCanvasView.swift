import AppKit
import MetalKit
import simd

protocol ImageCanvasDelegate: AnyObject {
    func canvasReadoutChanged(_ canvas: ImageCanvasView)
    func canvasWantsNavigation(_ canvas: ImageCanvasView, by delta: Int)
}

/// The image surface: zoom, pan, and the eyedropper.
final class ImageCanvasView: MTKView {
    weak var canvasDelegate: ImageCanvasDelegate?

    private var renderer: Renderer?
    private(set) var image: FloatImage?
    private var viewport = Viewport()

    /// EV offset applied at display time only. The readout always reports the
    /// file's own values, never the exposed ones — otherwise the numbers would
    /// describe a viewing decision rather than the image.
    var exposureEV: Float = 0 { didSet { needsDisplay = true } }

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
        clearColor = MTLClearColor(red: 0.055, green: 0.055, blue: 0.055, alpha: 1)

        // A still image has no reason to redraw at 120 Hz. Draw on demand only —
        // this is most of what "lightweight" means in practice.
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true

        renderer = Renderer(pixelFormat: colorPixelFormat)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Content

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

    private var imageSize: CGSize {
        guard let i = image else { return .zero }
        return CGSize(width: i.width, height: i.height)
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
            guard unit != 0 else { return }
            zoomStep(pow(1.12, max(-3, min(3, -unit))),
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

    override func mouseDown(with e: NSEvent) {
        if spaceHeld { beginPan() }
    }

    override func mouseDragged(with e: NSEvent) {
        if panning { dragPan(e) } else { updateReadout(at: e.locationInWindow) }
    }

    override func mouseUp(with e: NSEvent) { endPan() }

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
        let x = Int(floor(ip.x)), y = Int(floor(ip.y))
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
    }

    override func draw(_ dirtyRect: NSRect) {
        renderer?.draw(in: self, viewport: viewport,
                       exposure: pow(2, exposureEV),
                       backingScale: window?.backingScaleFactor ?? 1)
    }
}
