import CoreGraphics
import Foundation

/// A decoded image held as straight-alpha linear RGBA float32.
///
/// One buffer feeds everything: the GPU texture, the eyedropper readout, and
/// (later) the histogram. That is deliberate — if the readout sampled a
/// different buffer than the one we drew, the numbers could disagree with the
/// pixels, which is the whole failure mode a diagnostic viewer exists to avoid.
///
/// Linear, not display-encoded: values are scene-referred, so an EXR pixel at
/// 8.0 is stored as 8.0 rather than clipped to white.
final class FloatImage {
    let width: Int
    let height: Int

    /// Straight-alpha linear RGBA, 4 floats per pixel, row-major, top-left origin.
    let pixels: UnsafeMutablePointer<Float>
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

    var isHDR: Bool { maxComponent > 1.0001 }

    /// Scene-referred rather than display-referred: the values describe light,
    /// not pixels already prepared for a screen. Decided from the file's own
    /// declared colour space and format, which is the part a file *does* record.
    var isSceneLinear: Bool {
        sourceColorSpace.localizedCaseInsensitiveContains("linear")
            || typeIdentifier == "com.ilm.openexr-image"
            || typeIdentifier == "public.radiance"
    }

    init(width: Int, height: Int, pixels: UnsafeMutablePointer<Float>,
         url: URL, typeIdentifier: String, sourceBitDepth: Int, sourceColorSpace: String,
         fullWidth: Int, fullHeight: Int, wasDownsampled: Bool, maxComponent: Float) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.count = width * height * 4
        self.url = url
        self.typeIdentifier = typeIdentifier
        self.sourceBitDepth = sourceBitDepth
        self.sourceColorSpace = sourceColorSpace
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
        self.wasDownsampled = wasDownsampled
        self.maxComponent = maxComponent
    }

    deinit {
        pixels.deallocate()
    }

    /// Linear RGBA at an integer pixel coordinate, or nil if outside the image.
    func sample(x: Int, y: Int) -> SIMD4<Float>? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        return SIMD4<Float>(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
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
