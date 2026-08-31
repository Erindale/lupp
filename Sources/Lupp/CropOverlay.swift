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

    private enum Grip {
        case move
        case corner(x: Int, y: Int)   // -1 leading/top, +1 trailing/bottom
        case edge(x: Int, y: Int)
    }

    private var drag: (grip: Grip, startCrop: SIMD4<Float>, startPoint: CGPoint)?
    private static let handle: CGFloat = 9
    private static let grabSlop: CGFloat = 11

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
        let dx = Float((p.x - d.startPoint.x) / img.width)
        let dy = Float((p.y - d.startPoint.y) / img.height)

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
        window?.invalidateCursorRects(for: self)
    }
}
