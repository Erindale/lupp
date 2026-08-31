import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum LoadError: LocalizedError {
    case notAnImage(URL)
    case decodeFailed(URL)
    case tooLarge(URL, Int)

    var errorDescription: String? {
        switch self {
        case .notAnImage(let u):  return "\(u.lastPathComponent) isn’t an image Lupp can read."
        case .decodeFailed(let u): return "Couldn’t decode \(u.lastPathComponent)."
        case .tooLarge(let u, let mp): return "\(u.lastPathComponent) is \(mp) megapixels — beyond Lupp’s limit."
        }
    }
}

enum ImageLoader {
    /// Above this, decode a reduced version rather than allocating float32 for the
    /// full frame. 120 MP of RGBA float32 is already ~1.9 GB; the guard exists so a
    /// stray .psb doesn't take the machine down. Downsampling is surfaced in the
    /// readout so you always know when you aren't looking at every pixel.
    static let maxPixels = 120_000_000
    static let hardMaxPixels = 2_000_000_000

    /// Every type ImageIO can decode on this machine, which is what Lupp claims to open.
    static var readableTypes: [String] {
        (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).sorted()
    }

    static func canRead(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return readableTypes.contains { UTType($0).map { t.conforms(to: $0) } ?? false }
    }

    static func load(url: URL) throws -> FloatImage {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { throw LoadError.notAnImage(url) }

        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let fullW = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let fullH = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let depth = props[kCGImagePropertyDepth] as? Int ?? 8
        let exif = (props[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up

        if fullW * fullH > hardMaxPixels { throw LoadError.tooLarge(url, fullW * fullH / 1_000_000) }

        // Float decoding is what keeps EXR and Radiance values above 1.0 intact.
        var decodeOpts: [CFString: Any] = [
            kCGImageSourceShouldAllowFloat: true,
            kCGImageSourceShouldCache: false,
        ]
        var downsampled = false
        var cg: CGImage?
        if fullW * fullH > maxPixels, fullW > 0, fullH > 0 {
            let scale = (Double(maxPixels) / Double(fullW * fullH)).squareRoot()
            decodeOpts[kCGImageSourceCreateThumbnailFromImageAlways] = true
            decodeOpts[kCGImageSourceThumbnailMaxPixelSize] = Int(Double(max(fullW, fullH)) * scale)
            decodeOpts[kCGImageSourceCreateThumbnailWithTransform] = true
            cg = CGImageSourceCreateThumbnailAtIndex(src, 0, decodeOpts as CFDictionary)
            downsampled = cg != nil
        }
        if cg == nil {
            cg = CGImageSourceCreateImageAtIndex(src, 0, decodeOpts as CFDictionary)
        }
        guard let image = cg else { throw LoadError.decodeFailed(url) }

        // kCGImageSourceCreateThumbnailWithTransform already applied orientation.
        let orientation: CGImagePropertyOrientation = downsampled ? .up : exif
        let buf = try rasterizeToLinearFloat(image, orientation: orientation)

        let typeID = (CGImageSourceGetType(src) as String?) ?? "public.data"
        let csName = image.colorSpace?.name.map { String($0 as String) } ?? "unknown"
        return FloatImage(
            width: buf.width, height: buf.height, pixels: buf.pixels,
            url: url, typeIdentifier: typeID, sourceBitDepth: depth,
            sourceColorSpace: shortColorSpaceName(csName),
            fullWidth: fullW, fullHeight: fullH, wasDownsampled: downsampled,
            maxComponent: buf.maxComponent)
    }

    // MARK: - Rasterization

    private struct Raster {
        let width: Int, height: Int
        let pixels: UnsafeMutablePointer<Float>
        let maxComponent: Float
    }

    /// Draw through CoreGraphics into an extended-range linear float context.
    /// CG performs the colour conversion, so a Display-P3 HEIC, an sRGB JPEG and a
    /// scene-linear EXR all land in the same well-defined space — which is what
    /// lets one eyedropper report meaningful numbers for all of them.
    private static func rasterizeToLinearFloat(_ image: CGImage,
                                               orientation: CGImagePropertyOrientation) throws -> Raster {
        let w = image.width, h = image.height
        let swap = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let ow = swap ? h : w
        let oh = swap ? w : h

        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            throw LoadError.decodeFailed(URL(fileURLWithPath: "/"))
        }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.floatComponents.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedLast.rawValue)

        let count = ow * oh * 4
        let pixels = UnsafeMutablePointer<Float>.allocate(capacity: count)
        pixels.initialize(repeating: 0, count: count)

        guard let ctx = CGContext(data: pixels, width: ow, height: oh,
                                  bitsPerComponent: 32, bytesPerRow: ow * 16,
                                  space: space, bitmapInfo: bitmapInfo.rawValue) else {
            pixels.deallocate()
            throw LoadError.decodeFailed(URL(fileURLWithPath: "/"))
        }
        ctx.interpolationQuality = .high
        applyOrientation(orientation, to: ctx, sourceWidth: w, sourceHeight: h,
                         outWidth: ow, outHeight: oh)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let maxC = unpremultiplyAndFindMax(pixels, pixelCount: ow * oh)
        return Raster(width: ow, height: oh, pixels: pixels, maxComponent: maxC)
    }

    /// CG's bitmap memory runs top-down while its coordinate origin is bottom-left,
    /// so an identity CTM already lands row 0 of the image at row 0 of the buffer.
    /// These transforms only add the EXIF rotation/mirroring on top of that.
    private static func applyOrientation(_ o: CGImagePropertyOrientation, to ctx: CGContext,
                                         sourceWidth w: Int, sourceHeight h: Int,
                                         outWidth ow: Int, outHeight oh: Int) {
        let fw = CGFloat(w), fh = CGFloat(h)
        let fow = CGFloat(ow), foh = CGFloat(oh)
        switch o {
        case .up:
            break
        case .upMirrored:
            ctx.translateBy(x: fw, y: 0);  ctx.scaleBy(x: -1, y: 1)
        case .down:
            ctx.translateBy(x: fw, y: fh); ctx.scaleBy(x: -1, y: -1)
        case .downMirrored:
            ctx.translateBy(x: 0, y: fh);  ctx.scaleBy(x: 1, y: -1)
        case .right:                              // 90° clockwise
            ctx.translateBy(x: 0, y: foh); ctx.rotate(by: -.pi / 2)
        case .left:                               // 90° counter-clockwise
            ctx.translateBy(x: fow, y: 0); ctx.rotate(by: .pi / 2)
        case .leftMirrored:                       // transpose
            ctx.translateBy(x: 0, y: foh); ctx.rotate(by: -.pi / 2)
            ctx.translateBy(x: fw, y: 0);  ctx.scaleBy(x: -1, y: 1)
        case .rightMirrored:                      // transverse
            ctx.translateBy(x: fow, y: 0); ctx.rotate(by: .pi / 2)
            ctx.translateBy(x: fw, y: 0);  ctx.scaleBy(x: -1, y: 1)
        @unknown default:
            break
        }
    }

    /// CG hands back premultiplied alpha; the readout wants the pixel's own colour,
    /// so divide it back out. Tracks the RGB maximum in the same pass — a second
    /// walk over a multi-hundred-megabyte buffer is not free.
    private static func unpremultiplyAndFindMax(_ p: UnsafeMutablePointer<Float>,
                                                pixelCount: Int) -> Float {
        var maxC: Float = 0
        for i in stride(from: 0, to: pixelCount * 4, by: 4) {
            let a = p[i + 3]
            if a > 0, a < 1 {
                let inv = 1 / a
                p[i] *= inv; p[i + 1] *= inv; p[i + 2] *= inv
            }
            maxC = max(maxC, max(p[i], max(p[i + 1], p[i + 2])))
        }
        return maxC
    }

    private static func shortColorSpaceName(_ n: String) -> String {
        n.replacingOccurrences(of: "kCGColorSpace", with: "")
    }
}
