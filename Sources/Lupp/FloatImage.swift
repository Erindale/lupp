import CoreGraphics
import Foundation

/// How a decoded image is held in memory.
///
/// Forcing every file into float32 is expensive in a way you can feel. A 24MP
/// JPEG carries eight bits a channel; expanding it costs 384MB of allocation
/// and a fifth of a second of colour conversion to store precision the file
/// never had. An EXR genuinely needs the floats, so both representations stay
/// and the loader picks per file.
///
/// This is a storage decision only. Everything above this line reads linear
/// floats and cannot tell the difference — which is the point, because a
/// diagnostic viewer whose numbers depend on an internal memory format would be
/// no use at all.
enum PixelStore {
    /// Straight-alpha linear RGBA, four floats per pixel.
    case linearFloat(UnsafeMutablePointer<Float>)
    /// Opaque sRGB-encoded RGBA, four bytes per pixel, the fourth unused.
    /// Metal linearises this in the sampler at no cost, so the conversion the
    /// float path pays for up front happens here for free, per pixel, only for
    /// the pixels actually on screen.
    case srgbBytes(UnsafeMutablePointer<UInt8>)

    var bytesPerPixel: Int {
        switch self {
        case .linearFloat: return 16
        case .srgbBytes:   return 4
        }
    }
}

/// Page-mapped storage for image buffers.
///
/// These are tens to hundreds of megabytes and are allocated and freed
/// constantly while you scroll a folder. `malloc` keeps freed blocks that size
/// in a cache to hand back quickly, which is the right call for most programs
/// and the wrong one here: the process footprint grew to well over twice what
/// was actually being held, and the excess got compressed and swapped. Mapping
/// the pages directly hands them back the moment an image is evicted.
///
/// The pages also arrive zeroed, which the float path would otherwise have to
/// pay for itself.
enum PixelBuffer {
    static func allocate(_ bytes: Int) -> UnsafeMutableRawPointer? {
        let p = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        return p == MAP_FAILED ? nil : p
    }

    static func free(_ p: UnsafeMutableRawPointer, _ bytes: Int) {
        munmap(p, bytes)
    }
}

/// One sRGB byte's linear value, all 256 of them worked out once.
///
/// The scopes sample hundreds of thousands of pixels at load; a table turns
/// that from hundreds of thousands of `pow` calls into an array read.
private let srgbByteToLinear: [Float] = (0..<256).map { srgbToLinear(Float($0) / 255) }

/// A decoded image, presented as straight-alpha linear RGBA float.
///
/// One buffer feeds everything: the GPU texture, the eyedropper readout, and
/// the source statistics. That is deliberate — if the readout sampled a
/// different buffer than the one we drew, the numbers could disagree with the
/// pixels, which is the whole failure mode a diagnostic viewer exists to avoid.
///
/// Linear, not display-encoded: values are scene-referred, so an EXR pixel at
/// 8.0 reads as 8.0 rather than clipped to white.
final class FloatImage {
    let width: Int
    let height: Int

    let storage: PixelStore
    let count: Int

    // Provenance, for the readout bar.
    let url: URL
    let typeIdentifier: String
    let sourceBitDepth: Int
    let sourceColorSpace: String
    /// Pixel dimensions before any oversize downsample; equals width/height normally.
    let fullWidth: Int
    let fullHeight: Int
    let wasDownsampled: Bool

    /// Largest component found anywhere in the image. > 1.0 means the file
    /// carries values brighter than diffuse white and the histogram must not clamp.
    let maxComponent: Float

    /// What the file says about itself, read on the loading thread. Empty for
    /// images Lupp made rather than opened.
    let metadata: [ImageMetadata.Section]

    /// Measured once, at load, on the thread that did the decoding. These
    /// describe the file and never change, so recomputing them on every visit
    /// would be work done to reach the same answer.
    private(set) lazy var sourceStats: Scopes.Stats = Scopes.sourceStats(from: self)

    /// What this image costs to keep, for the cache's accounting.
    var bytesUsed: Int { width * height * storage.bytesPerPixel }

    var isHDR: Bool { maxComponent > 1.0001 }

    /// Scene-referred rather than display-referred: the values describe light,
    /// not pixels already prepared for a screen. Decided from the file's own
    /// declared colour space and format, which is the part a file *does* record.
    var isSceneLinear: Bool {
        sourceColorSpace.localizedCaseInsensitiveContains("linear")
            || typeIdentifier == "com.ilm.openexr-image"
            || typeIdentifier == "public.radiance"
    }

    init(width: Int, height: Int, storage: PixelStore,
         url: URL, typeIdentifier: String, sourceBitDepth: Int, sourceColorSpace: String,
         fullWidth: Int, fullHeight: Int, wasDownsampled: Bool, maxComponent: Float,
         metadata: [ImageMetadata.Section] = []) {
        self.width = width
        self.height = height
        self.storage = storage
        self.count = width * height * 4
        self.url = url
        self.typeIdentifier = typeIdentifier
        self.sourceBitDepth = sourceBitDepth
        self.sourceColorSpace = sourceColorSpace
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
        self.wasDownsampled = wasDownsampled
        self.maxComponent = maxComponent
        self.metadata = metadata
    }

    deinit {
        switch storage {
        case .linearFloat(let p): PixelBuffer.free(UnsafeMutableRawPointer(p), bytesUsed)
        case .srgbBytes(let p):   PixelBuffer.free(UnsafeMutableRawPointer(p), bytesUsed)
        }
    }

    /// Linear RGB at a flat pixel index. No bounds check — callers walk a range
    /// they already know is inside the image.
    @inline(__always)
    func linearRGB(atPixel i: Int) -> SIMD3<Float> {
        let o = i * 4
        switch storage {
        case .linearFloat(let p):
            return SIMD3(p[o], p[o + 1], p[o + 2])
        case .srgbBytes(let p):
            return SIMD3(srgbByteToLinear[Int(p[o])],
                         srgbByteToLinear[Int(p[o + 1])],
                         srgbByteToLinear[Int(p[o + 2])])
        }
    }

    /// Linear RGBA at an integer pixel coordinate, or nil if outside the image.
    func sample(x: Int, y: Int) -> SIMD4<Float>? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = y * width + x
        let rgb = linearRGB(atPixel: i)
        switch storage {
        case .linearFloat(let p):
            return SIMD4(rgb.x, rgb.y, rgb.z, p[i * 4 + 3])
        case .srgbBytes:
            // The byte path is only ever chosen for files with no alpha channel,
            // so the fourth byte is padding CoreGraphics never wrote. Reporting
            // it would be reporting uninitialised memory.
            return SIMD4(rgb.x, rgb.y, rgb.z, 1)
        }
    }
}

/// sRGB -> linear, for turning the shader's encoded output back into
/// tristimulus values the CIE scope can use.
func srgbToLinear(_ c: Float) -> Float {
    let v = min(max(c, 0), 1)
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

/// Linear -> sRGB display encoding, for the hex/8-bit half of the readout.
/// Values outside 0...1 are clamped here *only*; the float readout beside it
/// still shows what the file actually contains.
func linearToSRGB(_ c: Float) -> Float {
    let v = min(max(c, 0), 1)
    return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
}
