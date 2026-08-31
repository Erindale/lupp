import AppKit
import simd

/// The crop rectangle drawn over the canvas, with handles.
///
/// A sibling view above the Metal layer rather than something drawn in the
/// shader: handles need hit-testing and a cursor, and AppKit already does both.
/// It stays in image coordinates so the crop means the same thing at any zoom,
/// and converts only at draw and hit time.
final class CropOverlayView: NSView {
    /// Normalised crop, origin top-left, as stored in the display state.
    var crop = SIMD4<Float>(0, 0, 1, 1) { didSet { needsDisplay = true } }

    /// Maps the image's normalised space into this view. Supplied by the canvas,
    /// which owns the viewport.
    var imageRectProvider: (() -> CGRect)?
    var onChange: ((SIMD4<Float>) -> Void)?
    /// Renders a magnified, graded patch of the source around a point in image
    /// pixels. Supplied by the canvas.
    var loupeProvider: ((CGPoint, Int, Int) -> CGImage?)?
    /// Size of the source in pixels, for reporting and for the loupe.
    var imagePixelSize: (() -> CGSize)?

    private enum Grip {
        case move
        case corner(x: Int, y: Int)   // -1 leading/top, +1 trailing/bottom
        case edge(x: Int, y: Int)
    }

    private var drag: (grip: Grip, startCrop: SIMD4<Float>, startPoint: CGPoint)?
    private static let handle: CGFloat = 9
    private static let grabSlop: CGFloat = 11

    /// Shift slows the drag to a tenth and puts a magnifier under the cursor —
    /// the two halves of the same intent: place this edge exactly.
    static let fineFactor: Float = 0.1
    private static let loupeSize: CGFloat = 132
    private static let loupeSourcePixels = 48

    private var loupe: (image: CGImage, at: CGPoint, pixel: CGPoint)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var imageRect: CGRect { imageRectProvider?() ?? bounds }

    private var cropRect: CGRect {
        let r = imageRect
        return CGRect(x: r.minX + CGFloat(crop.x) * r.width,
                      y: r.minY + CGFloat(crop.y) * r.height,
                      width: CGFloat(crop.z) * r.width,
                      height: CGFloat(crop.w) * r.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let img = imageRect
        let c = cropRect
        guard img.width > 1, img.height > 1 else { return }

        // Dim what will be discarded, rather than hiding it: you still need to
        // see what you're cutting off to know whether the cut is right.
        NSColor.black.withAlphaComponent(0.55).setFill()
        for piece in [
            CGRect(x: img.minX, y: img.minY, width: img.width, height: c.minY - img.minY),
            CGRect(x: img.minX, y: c.maxY, width: img.width, height: img.maxY - c.maxY),
            CGRect(x: img.minX, y: c.minY, width: c.minX - img.minX, height: c.height),
            CGRect(x: c.maxX, y: c.minY, width: img.maxX - c.maxX, height: c.height),
        ] where piece.width > 0 && piece.height > 0 {
            piece.fill()
        }

        // Thirds, which is what the guides are actually for.
        NSColor.white.withAlphaComponent(0.22).setStroke()
        let thirds = NSBezierPath()
        for i in 1...2 {
            let f = CGFloat(i) / 3
            thirds.move(to: NSPoint(x: c.minX + c.width * f, y: c.minY))
            thirds.line(to: NSPoint(x: c.minX + c.width * f, y: c.maxY))
            thirds.move(to: NSPoint(x: c.minX, y: c.minY + c.height * f))
            thirds.line(to: NSPoint(x: c.maxX, y: c.minY + c.height * f))
        }
        thirds.lineWidth = 1
        thirds.stroke()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: c.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        NSColor.white.setFill()
        for p in handlePoints(in: c) {
            NSBezierPath(roundedRect: NSRect(x: p.x - CropOverlayView.handle / 2,
                                             y: p.y - CropOverlayView.handle / 2,
                                             width: CropOverlayView.handle,
                                             height: CropOverlayView.handle),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }

        drawLoupe()
    }

    private func drawLoupe() {
        guard let l = loupe, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = CropOverlayView.loupeSize
        // Kept inside the view, and nudged off the cursor so it isn't sitting
        // under the very edge being placed.
        var origin = CGPoint(x: l.at.x + 18, y: l.at.y + 18)
        origin.x = min(max(origin.x, 4), bounds.maxX - size - 4)
        origin.y = min(max(origin.y, 4), bounds.maxY - size - 22)
        let frame = CGRect(x: origin.x, y: origin.y, width: size, height: size)

        ctx.saveGState()
        let clip = NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5)
        clip.addClip()
        ctx.interpolationQuality = .none          // show pixels, not a blur of them
        // NSImage rather than CGContext.draw: this view is flipped, and drawing a
        // CGImage straight into a flipped context comes out upside down. NSImage
        // knows about the view's handedness.
        NSImage(cgImage: l.image, size: frame.size).draw(in: frame)
        ctx.restoreGState()

        // Crosshair on the exact point being placed.
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: frame.midX, y: frame.minY))
        cross.line(to: NSPoint(x: frame.midX, y: frame.maxY))
        cross.move(to: NSPoint(x: frame.minX, y: frame.midY))
        cross.line(to: NSPoint(x: frame.maxX, y: frame.midY))
        cross.lineWidth = 1
        cross.stroke()

        NSColor.white.withAlphaComponent(0.85).setStroke()
        clip.lineWidth = 1
        clip.stroke()

        let text = "\(Int(l.pixel.x)), \(Int(l.pixel.y))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let ts = text.size(withAttributes: attrs)
        let label = CGRect(x: frame.midX - ts.width / 2 - 4, y: frame.maxY + 3,
                           width: ts.width + 8, height: ts.height + 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: label, xRadius: 3, yRadius: 3).fill()
        text.draw(at: NSPoint(x: label.minX + 4, y: label.minY + 1), withAttributes: attrs)
    }

    private func handlePoints(in c: CGRect) -> [CGPoint] {
        [CGPoint(x: c.minX, y: c.minY), CGPoint(x: c.midX, y: c.minY), CGPoint(x: c.maxX, y: c.minY),
         CGPoint(x: c.minX, y: c.midY), CGPoint(x: c.maxX, y: c.midY),
         CGPoint(x: c.minX, y: c.maxY), CGPoint(x: c.midX, y: c.maxY), CGPoint(x: c.maxX, y: c.maxY)]
    }

    // MARK: - Hit testing

    /// Only claims the mouse where there is something to grab, so clicks that
    /// aren't aimed at the crop fall through to panning the image underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return grip(at: p) == nil ? nil : self
    }

    private func grip(at p: CGPoint) -> Grip? {
        let c = cropRect
        let slop = CropOverlayView.grabSlop
        let nearLeft = abs(p.x - c.minX) < slop
        let nearRight = abs(p.x - c.maxX) < slop
        let nearTop = abs(p.y - c.minY) < slop
        let nearBottom = abs(p.y - c.maxY) < slop
        let insideX = p.x > c.minX - slop && p.x < c.maxX + slop
        let insideY = p.y > c.minY - slop && p.y < c.maxY + slop

        if insideX, insideY {
            switch (nearLeft, nearRight, nearTop, nearBottom) {
            case (true, _, true, _):  return .corner(x: -1, y: -1)
            case (_, true, true, _):  return .corner(x: 1, y: -1)
            case (true, _, _, true):  return .corner(x: -1, y: 1)
            case (_, true, _, true):  return .corner(x: 1, y: 1)
            case (true, _, _, _):     return .edge(x: -1, y: 0)
            case (_, true, _, _):     return .edge(x: 1, y: 0)
            case (_, _, true, _):     return .edge(x: 0, y: -1)
            case (_, _, _, true):     return .edge(x: 0, y: 1)
            default: break
            }
        }
        return c.contains(p) ? .move : nil
    }

    override func resetCursorRects() {
        discardCursorRects()
        let c = cropRect
        addCursorRect(c, cursor: .openHand)
        for p in handlePoints(in: c) {
            addCursorRect(NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12),
                          cursor: .crosshair)
        }
    }

    // MARK: - Dragging

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let g = grip(at: p) else { return }
        drag = (g, crop, p)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = drag else { return }
        let img = imageRect
        guard img.width > 1, img.height > 1 else { return }
        let p = convert(e.locationInWindow, from: nil)
        var dx = Float((p.x - d.startPoint.x) / img.width)
        var dy = Float((p.y - d.startPoint.y) / img.height)

        // Shift slows the drag to a tenth: the pointer and the edge stop moving
        // together, which is the point — the edge can be placed finer than the
        // hand can hold still.
        let fine = e.modifierFlags.contains(.shift)
        if fine {
            dx *= CropOverlayView.fineFactor
            dy *= CropOverlayView.fineFactor
        }

        var c = d.startCrop
        // Never smaller than a pixel or two of the source, or the handles end up
        // on top of each other and it can't be recovered by dragging.
        let minSize: Float = 0.01


        switch d.grip {
        case .move:
            c.x = min(max(c.x + dx, 0), 1 - c.z)
            c.y = min(max(c.y + dy, 0), 1 - c.w)
        case .corner(let hx, let hy):
            applyEdge(&c, dx: dx, dy: dy, hx: hx, hy: hy, minSize: minSize)
        case .edge(let hx, let hy):
            applyEdge(&c, dx: dx, dy: dy, hx: hx, hy: hy, minSize: minSize)
        }
        crop = c
        onChange?(c)
        updateLoupe(showing: fine, grip: d.grip, at: p)
    }

    /// The magnifier follows the edge being moved, not the pointer: with a fine
    /// drag the two are no longer in the same place, and it is the edge you are
    /// trying to see.
    private func updateLoupe(showing: Bool, grip: Grip, at pointer: CGPoint) {
        guard showing, let px = imagePixelSize?(), px.width > 0 else {
            if loupe != nil { loupe = nil; needsDisplay = true }
            return
        }
        let c = crop
        var nx = c.x + c.z / 2, ny = c.y + c.w / 2
        switch grip {
        case .move: break
        case .corner(let hx, let hy), .edge(let hx, let hy):
            if hx < 0 { nx = c.x } else if hx > 0 { nx = c.x + c.z }
            if hy < 0 { ny = c.y } else if hy > 0 { ny = c.y + c.w }
        }
        let pixel = CGPoint(x: CGFloat(nx) * px.width, y: CGFloat(ny) * px.height)
        let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
        if let img = loupeProvider?(pixel, CropOverlayView.loupeSourcePixels,
                                    Int(CropOverlayView.loupeSize) * scale) {
            loupe = (img, pointer, pixel)
        }
        needsDisplay = true
    }

    private func applyEdge(_ c: inout SIMD4<Float>, dx: Float, dy: Float,
                           hx: Int, hy: Int, minSize: Float) {
        if hx < 0 {
            let nx = min(max(c.x + dx, 0), c.x + c.z - minSize)
            c.z += c.x - nx
            c.x = nx
        } else if hx > 0 {
            c.z = min(max(c.z + dx, minSize), 1 - c.x)
        }
        if hy < 0 {
            let ny = min(max(c.y + dy, 0), c.y + c.w - minSize)
            c.w += c.y - ny
            c.y = ny
        } else if hy > 0 {
            c.w = min(max(c.w + dy, minSize), 1 - c.y)
        }
    }

    override func mouseUp(with e: NSEvent) {
        drag = nil
        loupe = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
}
