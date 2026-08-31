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
              let s = Scopes.compute(from: img) else {
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
