import Accelerate
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
        let buf = canKeepBytes(image, sourceDepth: depth)
            ? try rasterizeToSRGBBytes(image, orientation: orientation)
            : try rasterizeToLinearFloat(image, orientation: orientation)

        let typeID = (CGImageSourceGetType(src) as String?) ?? "public.data"
        let csName = image.colorSpace?.name.map { String($0 as String) } ?? "unknown"
        // A camera stores a portrait frame as 6000 × 4000 plus "turn it", so the
        // file's own numbers describe the sensor rather than the photograph.
        // Report the picture, since that is what is on screen to be measured
        // against. The size checks above deliberately use the raw pair: the
        // pixel count is the same either way, and that is all they care about.
        let turned = [.left, .right, .leftMirrored, .rightMirrored].contains(exif)
        return FloatImage(
            width: buf.width, height: buf.height, storage: buf.storage,
            url: url, typeIdentifier: typeID, sourceBitDepth: depth,
            sourceColorSpace: shortColorSpaceName(csName),
            fullWidth: turned ? fullH : fullW, fullHeight: turned ? fullW : fullH,
            wasDownsampled: downsampled, maxComponent: buf.maxComponent)
    }

    /// Whether this image can be kept as sRGB bytes instead of linear floats.
    ///
    /// The test is whether the float buffer would carry any information the file
    /// does not already have. For an eight-bit, opaque, sRGB image it would not:
    /// every value in it is one of 256 levels, and the GPU linearises those in
    /// the sampler for nothing. Anything else takes the float path —
    ///
    /// - deeper than eight bits, where the extra levels are real;
    /// - carrying alpha, where compositing needs straight float values;
    /// - a wider gamut than sRGB, where bytes would clip colours the file holds.
    ///
    /// That last one is why this checks for sRGB exactly rather than accepting
    /// any display space. A Display P3 photograph converted into sRGB bytes
    /// loses the part of the gamut that made it worth shooting in P3.
    private static func canKeepBytes(_ image: CGImage, sourceDepth: Int) -> Bool {
        guard sourceDepth <= 8 else { return false }
        switch image.alphaInfo {
        case .none, .noneSkipLast, .noneSkipFirst: break
        default: return false
        }
        return image.colorSpace?.name == CGColorSpace.sRGB
    }

    // MARK: - Turning an image after the fact

    /// Turn a decoded image a quarter turn.
    ///
    /// For the times a file is simply wrong about which way up it is — no EXIF
    /// tag, or a tag nothing honoured when it was written. This works on the
    /// decoded pixels rather than re-reading the file, so it costs a buffer and
    /// about 30ms instead of another trip to the disk, and it never writes to
    /// the original.
    static func rotated(_ image: FloatImage, clockwise: Bool) -> FloatImage? {
        let w = image.width, h = image.height
        let ow = h, oh = w                      // a quarter turn always swaps the axes
        let turn = UInt8(clockwise ? kRotate90DegreesClockwise : kRotate90DegreesCounterClockwise)
        let bytes = ow * oh * image.storage.bytesPerPixel
        guard let outRaw = PixelBuffer.allocate(bytes) else { return nil }

        var err = kvImageNoError
        switch image.storage {
        case .srgbBytes(let p):
            var src = vImage_Buffer(data: p, height: vImagePixelCount(h),
                                    width: vImagePixelCount(w), rowBytes: w * 4)
            var dst = vImage_Buffer(data: outRaw, height: vImagePixelCount(oh),
                                    width: vImagePixelCount(ow), rowBytes: ow * 4)
            var background: [UInt8] = [0, 0, 0, 0]
            err = vImageRotate90_ARGB8888(&src, &dst, turn, &background,
                                          vImage_Flags(kvImageNoFlags))
        case .linearFloat(let p):
            var src = vImage_Buffer(data: p, height: vImagePixelCount(h),
                                    width: vImagePixelCount(w), rowBytes: w * 16)
            var dst = vImage_Buffer(data: outRaw, height: vImagePixelCount(oh),
                                    width: vImagePixelCount(ow), rowBytes: ow * 16)
            var background: [Float] = [0, 0, 0, 0]
            err = vImageRotate90_ARGBFFFF(&src, &dst, turn, &background,
                                          vImage_Flags(kvImageNoFlags))
        }
        guard err == kvImageNoError else {
            PixelBuffer.free(outRaw, bytes)
            return nil
        }

        let storage: PixelStore = {
            switch image.storage {
            case .srgbBytes:   return .srgbBytes(outRaw.bindMemory(to: UInt8.self, capacity: bytes))
            case .linearFloat: return .linearFloat(outRaw.bindMemory(to: Float.self,
                                                                    capacity: ow * oh * 4))
            }
        }()
        return FloatImage(
            width: ow, height: oh, storage: storage,
            url: image.url, typeIdentifier: image.typeIdentifier,
            sourceBitDepth: image.sourceBitDepth, sourceColorSpace: image.sourceColorSpace,
            fullWidth: image.fullHeight, fullHeight: image.fullWidth,
            wasDownsampled: image.wasDownsampled, maxComponent: image.maxComponent)
    }

    // MARK: - Rasterization

    private struct Raster {
        let width: Int, height: Int
        let storage: PixelStore
        let maxComponent: Float
    }

    /// The quarter turns EXIF asks for on a photograph.
    ///
    /// Worth naming separately from the full orientation set because these four
    /// move whole pixels to whole pixels — no resampling, no interpolation, just
    /// rows and columns going somewhere else. The mirrored orientations are rare
    /// enough that CoreGraphics can keep having them.
    private enum QuarterTurn {
        case none, cw90, ccw90, half

        init?(_ o: CGImagePropertyOrientation) {
            switch o {
            case .up:    self = .none
            case .down:  self = .half
            case .right: self = .cw90     // "rotate 90° clockwise to display"
            case .left:  self = .ccw90
            default:     return nil
            }
        }

        var swapsAxes: Bool { self == .cw90 || self == .ccw90 }

        var vImageConstant: UInt8 {
            switch self {
            case .none:  return UInt8(kRotate0DegreesClockwise)
            case .cw90:  return UInt8(kRotate90DegreesClockwise)
            case .ccw90: return UInt8(kRotate90DegreesCounterClockwise)
            case .half:  return UInt8(kRotate180DegreesClockwise)
            }
        }
    }

    /// Draw an eight-bit sRGB image into sRGB bytes — the cheap path.
    ///
    /// No colour conversion, no float expansion, no unpremultiply pass: a 24MP
    /// frame lands in 96MB instead of 384MB and takes roughly a third of the
    /// time. The sRGB decode still happens, but on the GPU, in the sampler, for
    /// the pixels actually being displayed.
    ///
    /// Rotation is done afterwards rather than as part of the draw. A rotated
    /// `draw` is a general affine transform to CoreGraphics and costs three
    /// times a flat one, even at 90° where nothing needs resampling — which
    /// matters, because half the photographs anyone takes are portrait.
    private static func rasterizeToSRGBBytes(_ image: CGImage,
                                             orientation: CGImagePropertyOrientation) throws -> Raster {
        guard let turn = QuarterTurn(orientation) else {
            return try rasterizeToSRGBBytesViaCG(image, orientation: orientation)
        }
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw LoadError.decodeFailed(URL(fileURLWithPath: "/"))
        }
        // noneSkipLast, not premultipliedLast: the caller has already checked the
        // image is opaque, so there is no alpha to divide back out afterwards.
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)

        guard let flatRaw = PixelBuffer.allocate(w * h * 4) else {
            throw LoadError.decodeFailed(URL(fileURLWithPath: "/"))
        }
        let flat = flatRaw.bindMemory(to: UInt8.self, capacity: w * h * 4)
        guard let ctx = CGContext(data: flat, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: bitmapInfo.rawValue) else {
            PixelBuffer.free(flatRaw, w * h * 4)
            throw LoadError.decodeFailed(URL(fileURLWithPath: "/"))
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Eight-bit sRGB cannot express a value above diffuse white, so the
        // maximum is 1.0 by construction rather than by measurement.
        if turn == .none {
            return Raster(width: w, height: h, storage: .srgbBytes(flat), maxComponent: 1)
        }

        let ow = turn.swapsAxes ? h : w
        let oh = turn.swapsAxes ? w : h
        guard let outRaw = PixelBuffer.allocate(ow * oh * 4) else {
            PixelBuffer.free(flatRaw, w * h * 4)
            throw LoadError.decodeFailed(URL(fileURLWithPath: "/"))
        }
        let out = outRaw.bindMemory(to: UInt8.self, capacity: ow * oh * 4)
        var src = vImage_Buffer(data: flat, height: vImagePixelCount(h),
                                width: vImagePixelCount(w), rowBytes: w * 4)
        var dst = vImage_Buffer(data: out, height: vImagePixelCount(oh),
                                width: vImagePixelCount(ow), rowBytes: ow * 4)
        var background: [UInt8] = [0, 0, 0, 0]
        let err = vImageRotate90_ARGB8888(&src, &dst, turn.vImageConstant,
                                          &background, vImage_Flags(kvImageNoFlags))
        PixelBuffer.free(flatRaw, w * h * 4)
        guard err == kvImageNoError else {
            PixelBuffer.free(outRaw, ow * oh * 4)
            throw LoadError.decodeFailed(URL(fileURLWithPath: "/"))
        }
        return Raster(width: ow, height: oh, storage: .srgbBytes(out), maxComponent: 1)
    }

    /// The mirrored orientations, which vImage's quarter turns don't cover.
    private static func rasterizeToSRGBBytesViaCG(_ image: CGImage,
                                                  orientation: CGImagePropertyOrientation) throws -> Raster {
        let w = image.width, h = image.height
        let swap = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let ow = swap ? h : w
        let oh = swap ? w : h

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw LoadError.decodeFailed(URL(fileURLWithPath: "/"))
        }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)

        guard let raw = PixelBuffer.allocate(ow * oh * 4) else {
            throw LoadError.decodeFailed(URL(fileURLWithPath: "/"))
        }
        let pixels = raw.bindMemory(to: UInt8.self, capacity: ow * oh * 4)
        guard let ctx = CGContext(data: pixels, width: ow, height: oh,
                                  bitsPerComponent: 8, bytesPerRow: ow * 4,
                                  space: space, bitmapInfo: bitmapInfo.rawValue) else {
            PixelBuffer.free(raw, ow * oh * 4)
            throw LoadError.decodeFailed(URL(fileURLWithPath: "/"))
        }
        ctx.interpolationQuality = .high
        applyOrientation(orientation, to: ctx, sourceWidth: w, sourceHeight: h,
                         outWidth: ow, outHeight: oh)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Raster(width: ow, height: oh, storage: .srgbBytes(pixels), maxComponent: 1)
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

        // Already zeroed, because the kernel hands out fresh anonymous pages
        // that way. That matters for an image with alpha: `draw` composites
        // source-over, so whatever is in the buffer shows through the
        // transparent parts, and a 384MB memset to guarantee it would have cost
        // around 40ms of every load.
        guard let raw = PixelBuffer.allocate(ow * oh * 16) else {
            throw LoadError.decodeFailed(URL(fileURLWithPath: "/"))
        }
        let pixels = raw.bindMemory(to: Float.self, capacity: ow * oh * 4)

        guard let ctx = CGContext(data: pixels, width: ow, height: oh,
                                  bitsPerComponent: 32, bytesPerRow: ow * 16,
                                  space: space, bitmapInfo: bitmapInfo.rawValue) else {
            PixelBuffer.free(raw, ow * oh * 16)
            throw LoadError.decodeFailed(URL(fileURLWithPath: "/"))
        }
        ctx.interpolationQuality = .high
        applyOrientation(orientation, to: ctx, sourceWidth: w, sourceHeight: h,
                         outWidth: ow, outHeight: oh)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let maxC = unpremultiplyAndFindMax(pixels, pixelCount: ow * oh)
        return Raster(width: ow, height: oh, storage: .linearFloat(pixels), maxComponent: maxC)
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
