import AppKit
import CoreGraphics
import Foundation
import ImageIO
import simd
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
        storagePathIsChosenWell(in: dir)
        manualRotation(in: dir)
        hdrSurvivesDecode(in: dir)
        exifOrientationApplied(in: dir)
        alphaIsStraight(in: dir)
        viewportAnchorHolds()
        openingZoomRules(in: dir)
        scopesReadDisplayEncoded(in: dir)
        cubeLUTParses(in: dir)
        sessionRoundTrips(in: dir)
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

    /// Which storage a file lands in, and that the choice is invisible above it.
    ///
    /// The byte path exists to be fast, so the thing to guard is that it is also
    /// *correct*: same linear values as the float path, and never chosen for a
    /// file whose extra information it would throw away.
    private static func storagePathIsChosenWell(in dir: URL) {
        let opaque = dir.appendingPathComponent("opaque.png")
        let bytes: [UInt8] = [128, 128, 128, 255,  255, 0, 0, 255,  0, 0, 0, 255]
        guard writeOpaqueSRGB(bytes, width: 3, height: 1, to: opaque),
              let img = try? ImageLoader.load(url: opaque) else {
            return fail("storage", "could not round-trip an opaque sRGB PNG")
        }
        if case .srgbBytes = img.storage {
            check("an opaque 8-bit sRGB image is kept as bytes", true, detail: "4 bytes/px")
        } else {
            check("an opaque 8-bit sRGB image is kept as bytes", false, detail: "took the float path")
        }
        // The same numbers the float path produces, from a quarter of the memory.
        let mid = img.sample(x: 0, y: 0)!
        let red = img.sample(x: 1, y: 0)!
        check("byte path linearizes exactly as the float path does",
              near(mid.x, 0.2159, tol: 0.004) && near(red.x, 1, tol: 0.002)
                  && near(red.y, 0, tol: 0.002),
              detail: String(format: "grey %.4f (want 0.2159), red %.3f %.3f", mid.x, red.x, red.y))
        // Opaque means opaque: the fourth byte is padding, and must never be read.
        check("byte path reports opaque alpha", mid.w == 1 && red.w == 1,
              detail: String(format: "alpha %.2f / %.2f", mid.w, red.w))
        check("byte path costs 4 bytes a pixel", img.bytesUsed == 3 * 4,
              detail: "\(img.bytesUsed) bytes for 3 pixels")

        // Alpha carries compositing information that 8 bits of padding cannot.
        let withAlpha = dir.appendingPathComponent("alpha-storage.png")
        if writeInteger([255, 0, 0, 128], width: 1, height: 1, to: withAlpha,
                        type: UTType.png.identifier),
           let a = try? ImageLoader.load(url: withAlpha) {
            if case .linearFloat = a.storage {
                check("an image with alpha stays float", true, detail: "16 bytes/px")
            } else {
                check("an image with alpha stays float", false, detail: "took the byte path")
            }
        }
    }

    /// Turning an image by hand, for files that are wrong about which way up
    /// they are. Both storage kinds, both directions, and back to where it
    /// started — a rotation that loses a pixel or turns the wrong way is the
    /// easy mistake, and it would be silently wrong rather than obviously so.
    private static func manualRotation(in dir: URL) {
        // 2 wide x 1 tall: red on the left, black on the right.
        let url = dir.appendingPathComponent("turn.png")
        guard writeOpaqueSRGB([255, 0, 0, 255,  0, 0, 0, 255], width: 2, height: 1, to: url),
              let img = try? ImageLoader.load(url: url) else {
            return fail("rotation", "could not round-trip")
        }

        // Clockwise: the left-hand pixel goes to the top.
        guard let cw = ImageLoader.rotated(img, clockwise: true) else {
            return fail("rotation", "clockwise turn failed")
        }
        check("a clockwise turn swaps the dimensions",
              cw.width == 1 && cw.height == 2 && cw.fullWidth == 1 && cw.fullHeight == 2,
              detail: "got \(cw.width)×\(cw.height)")
        check("a clockwise turn puts the left pixel on top",
              (cw.sample(x: 0, y: 0)?.x ?? 0) > 0.9 && (cw.sample(x: 0, y: 1)?.x ?? 1) < 0.1,
              detail: String(format: "top %.2f, bottom %.2f",
                             cw.sample(x: 0, y: 0)?.x ?? -1, cw.sample(x: 0, y: 1)?.x ?? -1))

        // And back again, which must land exactly where it started.
        guard let back = ImageLoader.rotated(cw, clockwise: false) else {
            return fail("rotation", "anticlockwise turn failed")
        }
        let same = (0..<(img.width * img.height)).allSatisfy {
            simd_length(back.linearRGB(atPixel: $0) - img.linearRGB(atPixel: $0)) < 0.001
        }
        check("turning back returns the original pixels",
              same && back.width == img.width && back.height == img.height,
              detail: "got \(back.width)×\(back.height)")

        // The float path has its own vImage entry point, so it needs its own proof.
        let exr = dir.appendingPathComponent("turn.exr")
        if writeFloat([4.0, 0, 0, 1,  0, 0, 0, 1], width: 2, height: 1, to: exr,
                      type: "com.ilm.openexr-image"),
           let f = try? ImageLoader.load(url: exr),
           case .linearFloat = f.storage,
           let fcw = ImageLoader.rotated(f, clockwise: true) {
            check("a float image turns too, keeping values above 1.0",
                  fcw.width == 1 && fcw.height == 2
                      && near(fcw.sample(x: 0, y: 0)?.x ?? 0, 4.0, tol: 0.01),
                  detail: String(format: "%dx%d, top %.2f", fcw.width, fcw.height,
                                 fcw.sample(x: 0, y: 0)?.x ?? -1))
        } else {
            fail("rotation", "could not turn a float image")
        }
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
        if case .linearFloat = img.storage {
            check("a scene-linear image stays float", true, detail: "16 bytes/px")
        } else {
            check("a scene-linear image stays float", false, detail: "took the byte path")
        }
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
        // The readout quotes these, so they have to describe the photograph and
        // not the sensor it came off.
        check("EXIF 6 swaps the reported full size",
              img.fullWidth == 2 && img.fullHeight == 4,
              detail: "got \(img.fullWidth)×\(img.fullHeight), want 2×4")
        if img.width == 2, img.height == 4 {
            let topRight = img.sample(x: 1, y: 0)!
            check("EXIF 6 rotates clockwise", topRight.x > 0.9,
                  detail: String(format: "top-right red = %.3f, want ~1", topRight.x))
        }

        // The byte path turns images with vImage rather than with a rotated
        // draw, so it needs its own proof — and all four quarter turns, since
        // getting the direction backwards is the obvious way to break it.
        for (exif, wantW, wantH, corner) in [(UInt32(1), 4, 2, (0, 0)),
                                             (UInt32(3), 4, 2, (3, 1)),
                                             (UInt32(6), 2, 4, (1, 0)),
                                             (UInt32(8), 2, 4, (0, 3))] {
            let u = dir.appendingPathComponent("rot-bytes-\(exif).png")
            guard writeOpaqueSRGB(bytes, width: 4, height: 2, to: u, orientation: exif),
                  let r = try? ImageLoader.load(url: u) else {
                fail("EXIF bytes \(exif)", "could not round-trip"); continue
            }
            guard case .srgbBytes = r.storage else {
                fail("EXIF bytes \(exif)", "took the float path"); continue
            }
            let ok = r.width == wantW && r.height == wantH
                && (r.sample(x: corner.0, y: corner.1)?.x ?? 0) > 0.9
            check("byte path applies EXIF \(exif)", ok,
                  detail: "got \(r.width)×\(r.height), red expected at \(corner)")
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

        // The state every image now opens in. Checked field by field rather than
        // only through the renderer, because a default that quietly stops being
        // neutral is exactly the bug that makes a viewer untrustworthy: you would
        // be looking at a graded picture and have no reason to suspect it.
        check("a new image opens with nothing applied",
              plain.exposureEV == 0 && plain.whiteBalance == SIMD3<Float>(1, 1, 1)
                  && plain.contrast == 1 && plain.blackPoint == 0 && plain.whitePoint == 1
                  && !plain.tetraActive && !plain.cropEnabled && !plain.cropApplied
                  && plain.lutName == nil && !plain.showClipping && !plain.falseColour
                  && plain.channel == .rgb,
              detail: "EV \(plain.exposureEV), contrast \(plain.contrast), LUT \(plain.lutName ?? "none")")

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

        // Saturation. Neutral has to be exact, or opening an image alters it.
        var sat = plain
        sat.saturation = 1
        if let s1 = pixels(sat) {
            let same = zip(p, s1).allSatisfy { a, b in
                zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
            }
            check("saturation at 1.0 changes nothing", same, detail: "red \(s1[0])")
        }

        sat.saturation = 0
        guard let mono = pixels(sat) else { return fail("GPU saturation", "export failed") }
        check("saturation at 0 is monochrome",
              mono[0][0] == mono[0][1] && mono[0][1] == mono[0][2]
                  && mono[1][0] == mono[1][1] && mono[1][1] == mono[1][2],
              detail: "red became \(mono[0]), green \(mono[1])")
        // Rec.709 luma: red is much darker than green, which is the whole reason
        // a channel mixer is worth having.
        check("monochrome uses luma weights, not an average",
              mono[1][0] > mono[0][0] + 40,
              detail: "red \(mono[0][0]) vs green \(mono[1][0])")

        // The point of putting it after the cube warp: with red moved onto green,
        // a red pixel must desaturate to green's luma rather than red's. If the
        // order were the other way round these would be identical.
        var mixed = sat                      // saturation 0
        mixed.tetraActive = true
        mixed.tetra.red = SIMD4<Float>(0, 1, 0, 0)
        if let m = pixels(mixed) {
            check("saturation follows the cube warp, not the source",
                  Int(m[0][0]) > Int(mono[0][0]) + 40,
                  detail: "warped red → \(m[0][0]), unwarped → \(mono[0][0])")
        }

        // Bypassing it must restore the colour rather than merely stop moving it.
        var bypassed = sat                   // saturation 0
        bypassed.saturationOn = false
        if let b = pixels(bypassed) {
            check("bypassing saturation restores the colour",
                  b[0][0] > 250 && b[0][1] < 5, detail: "red \(b[0])")
        }

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

        // Log encodings, checked at their published anchors: 18% scene grey maps
        // to a documented code value in each. A curve that is subtly wrong looks
        // like a bad LUT rather than like a bug, so it is worth pinning.
        //
        // Driven through an identity LUT, so what comes back is the encoding
        // itself: a value in, its log code out.
        let idURL = dir.appendingPathComponent("identity.cube")
        var idLines = ["LUT_3D_SIZE 2"]
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 {
            idLines.append("\(r).0 \(g).0 \(b).0")
        }}}
        guard (try? idLines.joined(separator: "\n").write(to: idURL, atomically: true,
                                                          encoding: .utf8)) != nil,
              let idLUT = try? CubeLUT.parse(url: idURL), renderer.loadLUT(idLUT) else {
            return fail("log LUT", "could not build identity cube")
        }

        // Regression: an identity cube must change nothing. It didn't — a cube's
        // first and last entries are its endpoints, but a texture's first and last
        // texel centres sit half a texel inside the edge, so addressing 0…1
        // directly squeezed every LUT toward its middle. Small on a 64³ cube,
        // ruinous on a small one, and invisible without a case like this.
        var withIdentity = plain
        withIdentity.lutAmount = 1
        guard let iden = pixels(withIdentity) else { return fail("identity LUT", "export failed") }
        let untouched = zip(p, iden).allSatisfy { a, b in
            zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
        }
        check("an identity LUT changes nothing", untouched,
              detail: "grey \(p[2]) -> \(iden[2]), red \(p[0]) -> \(iden[0])")

        // A mid-grey source: sRGB 128 decodes to linear 0.21586, close enough to
        // 0.18 to compare against the published anchors with a loose tolerance.
        for (input, expected, name) in [(LUTInput.sLog3, 0.42, "S-Log3"),
                                        (LUTInput.logC3, 0.41, "LogC3"),
                                        (LUTInput.acescct, 0.41, "ACEScct"),
                                        (LUTInput.vLog, 0.44, "V-Log")] {
            var d = plain
            d.lutInput = input
            d.lutAmount = 1
            guard let out = pixels(d) else { return fail(name, "export failed") }
            let got = Double(out[2][0]) / 255.0
            check("\(name) puts mid grey near its published anchor",
                  abs(got - expected) < 0.06,
                  detail: String(format: "got %.3f, want ~%.2f", got, expected))
        }
        renderer.clearLUT()

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

    /// A session is only useful if reopening it puts you back exactly where you
    /// were, so every field is set to something distinctive and checked coming
    /// back — a value that silently reverts to its default would look like the
    /// session merely not having saved much.
    private static func sessionRoundTrips(in dir: URL) {
        var d = Renderer.DisplayState()
        d.viewTransform = .acesFilmic
        d.exposureEV = -1.75
        d.whiteBalance = SIMD3(1.31, 0.94, 0.77)
        d.contrast = 1.42
        d.contrastPivot = 0.21
        d.blackPoint = 0.031
        d.whitePoint = 0.87
        d.tetra.red = SIMD4(0.9, 0.12, 0.05, 0)
        d.tetra.cyan = SIMD4(0.04, 0.88, 0.93, 0)
        d.tetraAmount = 0.63
        d.tetraActive = true
        d.lutAmount = 0.41
        d.lutInput = .vLog
        d.crop = SIMD4(0.11, 0.22, 0.55, 0.44)
        d.cropEnabled = true
        d.cropApplied = true
        d.gradeEnabled = false
        d.lightOn = false
        d.whiteBalanceOn = true
        d.tetraOn = false
        d.lutOn = true
        d.channel = .blue
        d.showClipping = true
        d.falseColour = false

        let image = URL(fileURLWithPath: dir.appendingPathComponent("ref.png").path)
        let url = dir.appendingPathComponent("s.\(Session.fileExtension)")
        let written = Session.from(d, image: image, lutPath: "/tmp/x.cube")
        guard (try? written.write(to: url)) != nil,
              let back = try? Session.read(from: url) else {
            return fail("session", "could not write or read back")
        }

        var r = Renderer.DisplayState()
        back.apply(to: &r)

        check("session restores the light section",
              r.exposureEV == d.exposureEV && r.contrast == d.contrast
                  && r.contrastPivot == d.contrastPivot && r.blackPoint == d.blackPoint
                  && r.whitePoint == d.whitePoint && r.whiteBalance == d.whiteBalance,
              detail: "EV \(r.exposureEV) contrast \(r.contrast) wb \(r.whiteBalance)")
        check("session restores the cube corners and mix",
              r.tetra == d.tetra && r.tetraAmount == d.tetraAmount && r.tetraActive,
              detail: "red \(r.tetra.red) cyan \(r.tetra.cyan) mix \(r.tetraAmount)")
        check("session restores the crop",
              r.crop == d.crop && r.cropEnabled && r.cropApplied,
              detail: "\(r.crop) enabled=\(r.cropEnabled) applied=\(r.cropApplied)")
        check("session restores LUT choice, amount and input",
              back.lutPath == "/tmp/x.cube" && r.lutAmount == d.lutAmount && r.lutInput == .vLog,
              detail: "\(back.lutPath ?? "nil") amount \(r.lutAmount) input \(r.lutInput)")
        check("session restores bypasses and view state",
              r.gradeEnabled == false && r.lightOn == false && r.tetraOn == false
                  && r.whiteBalanceOn && r.lutOn
                  && r.channel == .blue && r.showClipping && !r.falseColour,
              detail: "grade \(r.gradeEnabled) light \(r.lightOn) channel \(r.channel)")
        check("session records which image it belongs to",
              back.imagePath == image.path,
              detail: back.imagePath)
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

    /// An opaque, sRGB-tagged PNG — the shape of file the byte path is for.
    /// `writeInteger` tags DeviceRGB and keeps an alpha channel, both of which
    /// send a file down the float path on purpose.
    private static func writeOpaqueSRGB(_ bytes: [UInt8], width: Int, height: Int,
                                        to url: URL, orientation: UInt32? = nil) -> Bool {
        var data = bytes
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes: &data, count: data.count) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
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
