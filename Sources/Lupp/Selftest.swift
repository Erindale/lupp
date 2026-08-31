import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `Lupp --selftest` — checks the parts where being wrong is silent.
///
/// A viewer that reports colour is only useful if the numbers are right, and a
/// wrong colour transform or a dropped EXIF rotation looks perfectly plausible
/// on screen. These assertions are the things a screenshot cannot confirm.
enum Selftest {
    private static var failures = 0

    static func run() -> Int32 {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lupp-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        srgbLinearizes(in: dir)
        hdrSurvivesDecode(in: dir)
        exifOrientationApplied(in: dir)
        alphaIsStraight(in: dir)
        viewportAnchorHolds()
        openingZoomRules(in: dir)
        scopesReadDisplayEncoded(in: dir)
        cubeLUTParses(in: dir)
        gpuPathIsExact(in: dir)

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) FAILED")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Checks

    /// An 8-bit sRGB file must arrive linearized, or every readout is gamma-wrong.
    private static func srgbLinearizes(in dir: URL) {
        let url = dir.appendingPathComponent("srgb.png")
        let bytes: [UInt8] = [128, 128, 128, 255,   255, 0, 0, 255]
        guard writeInteger(bytes, width: 2, height: 1, to: url, type: UTType.png.identifier),
              let img = try? ImageLoader.load(url: url) else { return fail("sRGB", "could not round-trip") }

        let mid = img.sample(x: 0, y: 0)!
        // sRGB 128/255 -> linear 0.2159
        check("sRGB 50% grey linearizes", near(mid.x, 0.2159, tol: 0.004),
              detail: String(format: "got %.4f, want 0.2159", mid.x))

        let red = img.sample(x: 1, y: 0)!
        check("sRGB pure red stays 1,0,0",
              near(red.x, 1.0, tol: 0.002) && near(red.y, 0, tol: 0.002) && near(red.z, 0, tol: 0.002),
              detail: String(format: "got %.3f %.3f %.3f", red.x, red.y, red.z))
    }

    /// The reason the whole pipeline is float: EXR values above 1.0 must not clip.
    private static func hdrSurvivesDecode(in dir: URL) {
        let url = dir.appendingPathComponent("hdr.exr")
        let vals: [Float] = [0.5, 0.5, 0.5, 1,  8.0, 4.0, 2.0, 1]
        guard writeFloat(vals, width: 2, height: 1, to: url, type: "com.ilm.openexr-image"),
              let img = try? ImageLoader.load(url: url) else { return fail("EXR", "could not round-trip") }

        let hdr = img.sample(x: 1, y: 0)!
        check("EXR keeps values above 1.0",
              near(hdr.x, 8.0, tol: 0.01) && near(hdr.y, 4.0, tol: 0.01) && near(hdr.z, 2.0, tol: 0.01),
              detail: String(format: "got %.3f %.3f %.3f, want 8 4 2", hdr.x, hdr.y, hdr.z))
        check("HDR flagged in metadata", img.isHDR && img.maxComponent > 7.9,
              detail: String(format: "isHDR=%@ max=%.3f", img.isHDR ? "true" : "false", img.maxComponent))
    }

    /// EXIF 6 means "rotate 90° clockwise to display". Getting this wrong shows
    /// every phone photo on its side, so pin both the dimensions and a corner.
    private static func exifOrientationApplied(in dir: URL) {
        let url = dir.appendingPathComponent("rot.tiff")
        // 4 wide x 2 tall, red marker at top-left, everything else black.
        var bytes = [UInt8](repeating: 0, count: 4 * 2 * 4)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        bytes[0] = 255                                   // red at (0,0)

        guard writeInteger(bytes, width: 4, height: 2, to: url,
                           type: UTType.tiff.identifier, orientation: 6),
              let img = try? ImageLoader.load(url: url) else { return fail("EXIF", "could not round-trip") }

        check("EXIF 6 swaps dimensions", img.width == 2 && img.height == 4,
              detail: "got \(img.width)×\(img.height), want 2×4")
        if img.width == 2, img.height == 4 {
            let topRight = img.sample(x: 1, y: 0)!
            check("EXIF 6 rotates clockwise", topRight.x > 0.9,
                  detail: String(format: "top-right red = %.3f, want ~1", topRight.x))
        }
    }

    /// CG hands back premultiplied alpha; the readout wants the pixel's own colour.
    private static func alphaIsStraight(in dir: URL) {
        let url = dir.appendingPathComponent("alpha.png")
        // White at 50% alpha, stored straight in the PNG.
        let bytes: [UInt8] = [255, 255, 255, 128]
        guard writeInteger(bytes, width: 1, height: 1, to: url, type: UTType.png.identifier),
              let img = try? ImageLoader.load(url: url) else { return fail("alpha", "could not round-trip") }

        let p = img.sample(x: 0, y: 0)!
        check("half-transparent white reads as white, not grey",
              near(p.x, 1.0, tol: 0.02) && near(p.w, 0.502, tol: 0.01),
              detail: String(format: "got rgb %.3f a %.3f, want rgb 1.0 a 0.502", p.x, p.w))
    }

    /// The gesture guarantee: whatever pixel is under the cursor stays under it.
    private static func viewportAnchorHolds() {
        var vp = Viewport(scale: 1, origin: CGPoint(x: 37, y: -12))
        let anchor = CGPoint(x: 410, y: 233)
        let before = vp.imagePoint(fromView: anchor)
        vp.zoom(to: 6.4, anchor: anchor)
        let after = vp.imagePoint(fromView: anchor)
        check("zoom holds the point under the cursor",
              near(Float(before.x), Float(after.x), tol: 0.001) &&
              near(Float(before.y), Float(after.y), tol: 0.001),
              detail: "\(before) -> \(after)")

        vp.zoom(to: 1e9, anchor: anchor)
        check("zoom clamps at max", vp.scale == Viewport.maxScale, detail: "scale=\(vp.scale)")

        // Regression: a window larger than the image must not enlarge it unasked,
        // on open *or* on any later resize.
        let small = CGSize(width: 1200, height: 800)
        let bigView = CGSize(width: 2400, height: 1600)
        let auto = Viewport.fitScale(viewSize: bigView, imageSize: small,
                                     allowUpscale: false, oneToOne: 1.0)
        check("auto-fit never upscales past 1:1", auto == 1.0, detail: "scale=\(auto)")

        let explicit = Viewport.fitScale(viewSize: bigView, imageSize: small,
                                         allowUpscale: true, oneToOne: 1.0)
        check("explicit Zoom to Fit may upscale", explicit == 2.0, detail: "scale=\(explicit)")

        // On a 2× display 1:1 is 0.5 points per pixel, so the cap moves with it.
        let retina = Viewport.fitScale(viewSize: bigView, imageSize: small,
                                       allowUpscale: false, oneToOne: 0.5)
        check("auto-fit cap follows the display's backing scale", retina == 0.5,
              detail: "scale=\(retina)")
    }

    /// The three opening rules, driven through the real canvas rather than a copy
    /// of its logic: small images open at 100%, large ones scale to the window
    /// they open into, and resizing afterwards never changes the magnification.
    private static func openingZoomRules(in dir: URL) {
        _ = NSApplication.shared          // AppKit wants this before any NSView

        func imageFile(_ name: String, _ w: Int, _ h: Int) -> FloatImage? {
            let url = dir.appendingPathComponent(name)
            var bytes = [UInt8](repeating: 90, count: w * h * 4)
            for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
            guard writeInteger(bytes, width: w, height: h, to: url,
                               type: UTType.png.identifier) else { return nil }
            return try? ImageLoader.load(url: url)
        }
        guard let small = imageFile("small.png", 400, 300),
              let large = imageFile("large.png", 1400, 900) else {
            return fail("zoom rules", "could not build fixtures")
        }

        let canvas = ImageCanvasView()
        canvas.setFrameSize(NSSize(width: 700, height: 500))

        canvas.show(small)
        check("image smaller than the window opens at 100%",
              abs(canvas.zoomPercent - 100) < 0.01,
              detail: String(format: "%.1f%%", canvas.zoomPercent))

        canvas.show(large)
        // 700/1400 = 0.5 is the binding axis; 500/900 = 0.555.
        check("image larger than the window scales to fit it",
              abs(canvas.zoomPercent - 50) < 0.01,
              detail: String(format: "%.1f%%", canvas.zoomPercent))

        let before = canvas.zoomPercent
        canvas.setFrameSize(NSSize(width: 1300, height: 1000))
        check("growing the window doesn't change the zoom",
              abs(canvas.zoomPercent - before) < 0.01,
              detail: String(format: "%.1f%% -> %.1f%%", before, canvas.zoomPercent))

        canvas.setFrameSize(NSSize(width: 300, height: 220))
        check("shrinking the window doesn't change the zoom",
              abs(canvas.zoomPercent - before) < 0.01,
              detail: String(format: "%.1f%% -> %.1f%%", before, canvas.zoomPercent))
    }

    /// The scopes bin display-encoded values while the readout reports linear.
    /// That split is deliberate, so pin it: mid-grey must land mid-histogram, not
    /// at 21% where its linear value sits.
    private static func scopesReadDisplayEncoded(in dir: URL) {
        let url = dir.appendingPathComponent("scopes.png")
        // A flat sRGB 50% grey field.
        var bytes = [UInt8](repeating: 128, count: 64 * 64 * 4)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        guard writeInteger(bytes, width: 64, height: 64, to: url, type: UTType.png.identifier),
              let img = try? ImageLoader.load(url: url),
              let renderer = Renderer(pixelFormat: .rgba16Float) else {
            return fail("scopes", "could not set up")
        }
        renderer.upload(img)
        var plainDisplay = Renderer.DisplayState()
        plainDisplay.viewTransform = .standard
        guard let sampled = renderer.renderSampled(display: plainDisplay, maxDimension: 64),
              let s = Scopes.compute(graded: sampled.data, width: sampled.width,
                                     height: sampled.height,
                                     stats: Scopes.sourceStats(from: img)) else {
            return fail("scopes", "could not compute")
        }

        check("scopes report the linear mean", near(s.stats.mean.x, 0.2159, tol: 0.005),
              detail: String(format: "mean %.4f, want 0.2159", s.stats.mean.x))

        // Histogram raster is 256 wide; a 50% sRGB field must peak near column 128.
        let peakColumn = brightestColumn(of: s.histogram)
        check("histogram bins sRGB, not linear", abs(peakColumn - 128) <= 3,
              detail: "peak at column \(peakColumn), want ~128 (55 would mean linear)")

        check("no false clipping on a mid-grey field",
              s.stats.clippedHigh == 0 && s.stats.aboveOne == 0,
              detail: "high=\(s.stats.clippedHigh) aboveOne=\(s.stats.aboveOne)")
    }

    private static func brightestColumn(of image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return -1 }
        let w = image.width, h = image.height
        var best = -1, bestCount = 0
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for x in 0..<w {
                var n = 0
                for y in 0..<h where p[(y * w + x) * 4 + 3] > 0 { n += 1 }
                if n > bestCount { bestCount = n; best = x }
            }
        }
        return best
    }

    /// The .cube format stores red varying fastest. Getting that order wrong
    /// swaps the R and B axes of every LUT and looks almost plausible, so pin it
    /// with a LUT whose value encodes its own coordinates.
    private static func cubeLUTParses(in dir: URL) {
        let n = 4
        var lines = ["# test", "TITLE \"Coords\"", "LUT_3D_SIZE \(n)"]
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let d = Float(n - 1)
                    lines.append(String(format: "%.6f %.6f %.6f",
                                        Float(r) / d, Float(g) / d, Float(b) / d))
                }
            }
        }
        let url = dir.appendingPathComponent("coords.cube")
        guard (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil,
              let lut = try? CubeLUT.parse(url: url) else {
            return fail("cube LUT", "could not parse")
        }

        check("cube LUT reads its size", lut.size == n, detail: "got \(lut.size)")
        check("cube LUT entry count", lut.rgba.count == n * n * n * 4,
              detail: "got \(lut.rgba.count)")

        // Index 1 is (r:1, g:0, b:0) if red varies fastest.
        let second = (lut.rgba[4], lut.rgba[5], lut.rgba[6])
        check("cube LUT stores red fastest",
              near(second.0, 1.0 / 3, tol: 0.001) && second.1 == 0 && second.2 == 0,
              detail: String(format: "entry 1 = %.3f %.3f %.3f, want 0.333 0 0",
                             second.0, second.1, second.2))

        // A 1D LUT must expand to a cube rather than being read as 3D data.
        let one = dir.appendingPathComponent("curve.cube")
        let curve = ["LUT_1D_SIZE 4", "0 0 0", "0.25 0.25 0.25", "0.5 0.5 0.5", "1 1 1"]
        guard (try? curve.joined(separator: "\n").write(to: one, atomically: true, encoding: .utf8)) != nil,
              let lut1 = try? CubeLUT.parse(url: one) else {
            return fail("1D cube LUT", "could not parse")
        }
        check("1D LUT expands to a cube", lut1.wasOneDimensional && lut1.size == 4,
              detail: "1D=\(lut1.wasOneDimensional) size=\(lut1.size)")
    }

    /// Runs a known image through the real GPU shader via the export path.
    ///
    /// Everything else here tests the CPU side. This is the only check that the
    /// pixels Metal actually produces are the right ones — and because export
    /// shares the screen's shader, it covers both at once.
    private static func gpuPathIsExact(in dir: URL) {
        guard let renderer = Renderer(pixelFormat: .rgba16Float) else {
            return fail("GPU", "no Metal device")
        }
        let url = dir.appendingPathComponent("gpu.png")
        // Pure red, pure green, mid grey, white.
        let bytes: [UInt8] = [255, 0, 0, 255,  0, 255, 0, 255,
                              128, 128, 128, 255,  255, 255, 255, 255]
        guard writeInteger(bytes, width: 4, height: 1, to: url, type: UTType.png.identifier),
              let img = try? ImageLoader.load(url: url) else {
            return fail("GPU", "could not build fixture")
        }
        renderer.upload(img)
        let size = CGSize(width: img.width, height: img.height)

        func pixels(_ d: Renderer.DisplayState) -> [[UInt8]]? {
            guard let cg = renderer.exportImage(size: size, display: d, bitDepth: 8),
                  let data = cg.dataProvider?.data as Data? else { return nil }
            return (0..<4).map { i in Array(data[(i * 4)..<(i * 4 + 4)]) }
        }

        var plain = Renderer.DisplayState()
        plain.viewTransform = .standard
        guard let p = pixels(plain) else { return fail("GPU", "export failed") }

        check("GPU round-trips sRGB unchanged",
              p[0][0] > 250 && p[0][1] < 5 && p[2][0] >= 126 && p[2][0] <= 130 && p[3][0] > 250,
              detail: "red=\(p[0]) grey=\(p[2]) white=\(p[3])")

        // Identity corners must be a true no-op, or every grade starts skewed.
        var identity = plain
        identity.tetraActive = true
        guard let q = pixels(identity) else { return fail("GPU tetra", "export failed") }
        let same = zip(p, q).allSatisfy { a, b in
            zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
        }
        check("tetra with identity corners changes nothing", same,
              detail: "before \(p[0]) after \(q[0])")

        // Swap the red corner to green: red must become green, white must not move.
        var swapped = identity
        swapped.tetra.red = SIMD4<Float>(0, 1, 0, 0)
        guard let r = pixels(swapped) else { return fail("GPU tetra", "export failed") }
        check("moving the red corner moves red", r[0][1] > 200 && r[0][0] < 60,
              detail: "red became \(r[0])")
        check("tetra leaves white and grey alone",
              abs(Int(r[3][0]) - Int(p[3][0])) <= 2 && abs(Int(r[2][0]) - Int(p[2][0])) <= 2,
              detail: "white \(r[3]) grey \(r[2])")

        // The linear grade chain. Defaults must be a true no-op, or every image
        // is subtly altered just by opening it.
        var neutral = plain
        neutral.whiteBalance = SIMD3(1, 1, 1)
        neutral.contrast = 1
        neutral.blackPoint = 0
        neutral.whitePoint = 1
        guard let n = pixels(neutral) else { return fail("grade", "export failed") }
        let unchanged = zip(p, n).allSatisfy { a, b in
            zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
        }
        check("neutral light settings change nothing", unchanged,
              detail: "before \(p[2]) after \(n[2])")

        // +1 EV doubles the linear value. sRGB 128 decodes to linear 0.21586;
        // doubled that is 0.43172; re-encoded, 1.055 * 0.43172^(1/2.4) - 0.055
        // = 0.6885, which is 176 of 255.
        var pushed = plain
        pushed.exposureEV = 1
        guard let e = pixels(pushed) else { return fail("exposure", "export failed") }
        check("+1 EV doubles linear mid grey", abs(Int(e[2][0]) - 176) <= 2,
              detail: "grey became \(e[2][0]), want ~176")

        // White balance is a per-channel linear gain, so only its channel moves.
        var warmed = plain
        warmed.whiteBalance = SIMD3(1.5, 1, 1)
        guard let w = pixels(warmed) else { return fail("white balance", "export failed") }
        check("white balance moves only its own channel",
              w[2][0] > p[2][0] + 10 && abs(Int(w[2][1]) - Int(p[2][1])) <= 1,
              detail: "grey \(p[2]) -> \(w[2])")

        // Contrast pivots on 0.18: mid grey at 0.2159 sits just above the pivot,
        // so more contrast should lift it slightly, and black must stay black.
        var punchy = plain
        punchy.contrast = 1.6
        guard let k = pixels(punchy) else { return fail("contrast", "export failed") }
        check("contrast pivots around 0.18, leaving pure red's zero channels at zero",
              k[0][1] <= 1 && k[0][2] <= 1,
              detail: "red became \(k[0])")
        check("contrast above 1 lifts values above the pivot", k[2][0] >= p[2][0],
              detail: "grey \(p[2][0]) -> \(k[2][0])")

        // Black and white point are a levels remap: lifting black to the value a
        // pixel already holds must send that pixel to zero.
        var lifted = plain
        lifted.blackPoint = 0.2159      // linear value of sRGB 128
        guard let b = pixels(lifted) else { return fail("black point", "export failed") }
        check("black point at a pixel's own value sends it to black", b[2][0] <= 2,
              detail: "grey became \(b[2][0]), want 0")

        // Pulling white down to 0.5 doubles everything below it.
        var pulled = plain
        pulled.whitePoint = 0.5
        guard let wp = pixels(pulled) else { return fail("white point", "export failed") }
        check("white point at 0.5 doubles the linear range",
              abs(Int(wp[2][0]) - 176) <= 2,
              detail: "grey became \(wp[2][0]), want ~176 (same as +1 EV)")

        // Export end to end: render, write a real file, read it back and compare.
        // Covers the encode, the CGImage construction and the ImageIO write, none
        // of which the in-memory check above touches.
        let outURL = dir.appendingPathComponent("export.png")
        guard let cg = renderer.exportImage(size: size, display: plain, bitDepth: 8),
              let dest = CGImageDestinationCreateWithURL(outURL as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else { return fail("export", "could not render") }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest),
              let back = try? ImageLoader.load(url: outURL) else {
            return fail("export", "could not write or re-read")
        }
        check("exported file round-trips to the same pixels",
              back.width == 4 && back.height == 1
                  && near(back.sample(x: 0, y: 0)!.x, 1.0, tol: 0.01)
                  && near(back.sample(x: 2, y: 0)!.x, 0.2159, tol: 0.01),
              detail: "\(back.width)×\(back.height), red=\(back.sample(x: 0, y: 0)!.x)")
    }

    // MARK: - Helpers

    private static func writeInteger(_ bytes: [UInt8], width: Int, height: Int,
                                     to url: URL, type: String,
                                     orientation: UInt32? = nil) -> Bool {
        var data = bytes
        guard let provider = CGDataProvider(data: Data(bytes: &data, count: data.count) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)
        else { return false }
        var props: [CFString: Any] = [:]
        if let o = orientation { props[kCGImagePropertyOrientation] = o }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    private static func writeFloat(_ vals: [Float], width: Int, height: Int,
                                   to url: URL, type: String) -> Bool {
        var data = vals
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue |
                                CGBitmapInfo.byteOrder32Little.rawValue |
                                CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let provider = CGDataProvider(data: Data(bytes: &data, count: data.count * 4) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
                               bytesPerRow: width * 16, space: space, bitmapInfo: info,
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }

    private static func near(_ a: Float, _ b: Float, tol: Float) -> Bool { abs(a - b) <= tol }

    private static func check(_ name: String, _ ok: Bool, detail: String) {
        print("  \(ok ? "✓" : "✗") \(name)\(ok ? "" : "  — \(detail)")")
        if !ok { failures += 1 }
    }

    private static func fail(_ name: String, _ why: String) {
        print("  ✗ \(name) — \(why)")
        failures += 1
    }
}
