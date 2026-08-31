import CoreGraphics
import Foundation

/// Maps between image pixels and view points.
///
/// The canvas is a flipped NSView, so view space runs top-left origin, y down —
/// the same handedness as the image buffer. That removes a whole class of
/// off-by-a-flip bugs from the pan and eyedropper maths.
struct Viewport {
    /// View points per image pixel.
    var scale: CGFloat = 1
    /// View-space point where the image's top-left corner sits.
    var origin: CGPoint = .zero

    static let minScale: CGFloat = 0.01
    static let maxScale: CGFloat = 256

    func imagePoint(fromView p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale)
    }

    func viewPoint(fromImage p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + origin.x, y: p.y * scale + origin.y)
    }

    /// Zoom while holding one view point stationary — the gesture that makes
    /// scroll-to-zoom feel like it is tracking the cursor rather than the centre.
    mutating func zoom(to newScale: CGFloat, anchor: CGPoint) {
        let clamped = min(max(newScale, Self.minScale), Self.maxScale)
        let img = imagePoint(fromView: anchor)
        scale = clamped
        origin = CGPoint(x: anchor.x - img.x * clamped, y: anchor.y - img.y * clamped)
    }

    mutating func pan(by delta: CGSize) {
        origin.x += delta.width
        origin.y += delta.height
    }

    /// Centre when the image is smaller than the view on an axis; otherwise stop
    /// the edges travelling inside the view. Free panning past the edge feels
    /// broken when you are trying to inspect a corner.
    mutating func clamp(viewSize: CGSize, imageSize: CGSize) {
        let w = imageSize.width * scale, h = imageSize.height * scale
        if w <= viewSize.width  { origin.x = (viewSize.width  - w) / 2 }
        else { origin.x = min(0, max(viewSize.width  - w, origin.x)) }
        if h <= viewSize.height { origin.y = (viewSize.height - h) / 2 }
        else { origin.y = min(0, max(viewSize.height - h, origin.y)) }
    }

    static func fitScale(viewSize: CGSize, imageSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return 1 }
        return min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    }

    /// The single place that decides a fit scale, so the cap can't be applied on
    /// open and then quietly dropped on resize.
    ///
    /// `allowUpscale` is true only for an explicit Zoom to Fit. Automatic fitting
    /// stops at 1:1: enlarging an image without being asked shows the viewer's
    /// interpolation rather than the file, which is the opposite of the point.
    static func fitScale(viewSize: CGSize, imageSize: CGSize,
                         allowUpscale: Bool, oneToOne: CGFloat) -> CGFloat {
        let f = fitScale(viewSize: viewSize, imageSize: imageSize)
        return allowUpscale ? f : min(f, oneToOne)
    }

    static func initial(viewSize: CGSize, imageSize: CGSize, oneToOne: CGFloat) -> Viewport {
        var vp = Viewport()
        vp.scale = fitScale(viewSize: viewSize, imageSize: imageSize,
                            allowUpscale: false, oneToOne: oneToOne)
        vp.clamp(viewSize: viewSize, imageSize: imageSize)
        return vp
    }
}
