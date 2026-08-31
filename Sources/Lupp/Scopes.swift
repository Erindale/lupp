import CoreGraphics
import Foundation
import simd

/// Histogram, RGB parade and vectorscope, rasterised once per image.
///
/// Computed on the display-encoded (sRGB) values rather than the linear ones the
/// eyedropper reports. That is not an inconsistency: every grading tool — Resolve
/// included — puts its scopes in the display domain, and a linear histogram piles
/// almost everything into the bottom eighth of the graph and is unreadable. The
/// readout says linear, the scopes say sRGB, and both are labelled.
///
/// Rasterised once and cached because these are whole-image reductions: doing
/// them per frame would make panning cost as much as loading.
struct Scopes {
    let histogram: CGImage
    /// Three side-by-side channel panels.
    let paradeSplit: CGImage
    /// All three channels superimposed on one plot, as Resolve's combined view.
    /// Both are rasterised in the same pass — the second accumulation is cheap
    /// next to the walk over the pixels, and switching should be instant.
    let paradeCombined: CGImage
    /// Luma-only waveform, the scope Resolve leads with.
    let waveform: CGImage
    /// CIE 1931 xy scatter. Unlike the other scopes this is computed on *linear*
    /// tristimulus values — chromaticity is a property of the light, and running
    /// it on display-encoded values would put the points in the wrong place.
    let cie: CGImage
    let vectorscope: CGImage
    let stats: Stats

    struct Stats {
        var min = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var max = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var mean = SIMD3<Float>(repeating: 0)
        var clippedHigh = 0      // any channel >= 1.0
        var clippedLow = 0       // any channel <= 0.0
        var aboveOne = 0         // genuinely HDR samples
        var sampleCount = 0
    }

    /// Cap on samples examined. Beyond this the scopes are statistically
    /// identical and just slower, so stride over the image instead.
    private static let maxSamples = 600_000

    static func compute(from image: FloatImage) -> Scopes? {
        let total = image.width * image.height
        guard total > 0 else { return nil }
        let step = max(1, Int((Double(total) / Double(maxSamples)).rounded(.up)))

        let bins = 256
        var hist = [Int](repeating: 0, count: bins * 3)

        let pw = 168, ph = 256                       // one parade panel
        var parade = [Float](repeating: 0, count: pw * ph * 3)
        let cw = 512                                 // combined parade, full width
        var combined = [Float](repeating: 0, count: cw * ph * 3)

        let vs = 256
        var vector = [Float](repeating: 0, count: vs * vs)
        var wave = [Float](repeating: 0, count: cw * ph)
        var cieAcc = [Float](repeating: 0, count: CIE.size * CIE.size)

        var stats = Stats()
        var sum = SIMD3<Double>(repeating: 0)

        let p = image.pixels
        let w = image.width

        var i = 0
        while i < total {
            let o = i * 4
            let lin = SIMD3<Float>(p[o], p[o + 1], p[o + 2])

            stats.min = simd_min(stats.min, lin)
            stats.max = simd_max(stats.max, lin)
            sum += SIMD3<Double>(Double(lin.x), Double(lin.y), Double(lin.z))
            if lin.x > 1 || lin.y > 1 || lin.z > 1 { stats.aboveOne += 1 }
            if lin.x >= 1 || lin.y >= 1 || lin.z >= 1 { stats.clippedHigh += 1 }
            if lin.x <= 0 || lin.y <= 0 || lin.z <= 0 { stats.clippedLow += 1 }
            stats.sampleCount += 1

            // Display-encoded copy drives all three scopes.
            let e = SIMD3<Float>(linearToSRGB(lin.x), linearToSRGB(lin.y), linearToSRGB(lin.z))

            for c in 0..<3 {
                let v = e[c]
                let b = min(bins - 1, max(0, Int(v * Float(bins - 1))))
                hist[c * bins + b] += 1
            }

            // Parade: image column -> panel column, value -> row.
            let x = i % w
            let px = min(pw - 1, x * pw / w)
            let cx = min(cw - 1, x * cw / w)
            for c in 0..<3 {
                let row = min(ph - 1, max(0, Int((1 - e[c]) * Float(ph - 1))))
                parade[(c * ph + row) * pw + px] += 1
                combined[(c * ph + row) * cw + cx] += 1
            }

            // Luma waveform, full width.
            let lumaE = 0.2126 * e.x + 0.7152 * e.y + 0.0722 * e.z
            let lrow = min(ph - 1, max(0, Int((1 - lumaE) * Float(ph - 1))))
            wave[lrow * cw + cx] += 1

            // CIE xy, from the linear values.
            let X = 0.4124564 * lin.x + 0.3575761 * lin.y + 0.1804375 * lin.z
            let Y = 0.2126729 * lin.x + 0.7151522 * lin.y + 0.0721750 * lin.z
            let Z = 0.0193339 * lin.x + 0.1191920 * lin.y + 0.9503041 * lin.z
            let sumXYZ = X + Y + Z
            if sumXYZ > 1e-6 {
                let cxx = Int(X / sumXYZ / Float(CIE.xMax) * Float(CIE.size - 1))
                let cyy = Int((1 - Y / sumXYZ / Float(CIE.yMax)) * Float(CIE.size - 1))
                if cxx >= 0, cxx < CIE.size, cyy >= 0, cyy < CIE.size {
                    cieAcc[cyy * CIE.size + cxx] += 1
                }
            }

            // Vectorscope: BT.709 chroma of the display-encoded value.
            let y = 0.2126 * e.x + 0.7152 * e.y + 0.0722 * e.z
            let cb = (e.z - y) / 1.8556
            let cr = (e.x - y) / 1.5748
            let vx = Int((cb + 0.5) * Float(vs - 1))
            let vy = Int((0.5 - cr) * Float(vs - 1))
            if vx >= 0, vx < vs, vy >= 0, vy < vs { vector[vy * vs + vx] += 1 }

            i += step
        }

        if stats.sampleCount > 0 {
            let n = Double(stats.sampleCount)
            stats.mean = SIMD3<Float>(Float(sum.x / n), Float(sum.y / n), Float(sum.z / n))
        }

        guard let h = renderHistogram(hist, bins: bins),
              let pa = renderParade(parade, width: pw, height: ph),
              let co = renderCombinedParade(combined, width: cw, height: ph),
              let wf = renderWaveform(wave, width: cw, height: ph),
              let ci = renderCIE(cieAcc, size: CIE.size),
              let v = renderVectorscope(vector, size: vs) else { return nil }
        return Scopes(histogram: h, paradeSplit: pa, paradeCombined: co,
                      waveform: wf, cie: ci, vectorscope: v, stats: stats)
    }

    // MARK: - Rasterisers

    private static func renderHistogram(_ hist: [Int], bins: Int) -> CGImage? {
        let w = bins, h = 256
        var px = [UInt8](repeating: 0, count: w * h * 4)

        // Ignore the extreme bins when scaling: a large flat background or a
        // clipped highlight otherwise flattens everything else to nothing.
        var peak = 1
        for c in 0..<3 {
            for b in 1..<(bins - 1) { peak = Swift.max(peak, hist[c * bins + b]) }
        }

        for x in 0..<w {
            for c in 0..<3 {
                let n = hist[c * bins + x]
                let barTop = h - Swift.min(h, Int(Double(n) / Double(peak) * Double(h)))
                if barTop >= h { continue }
                for y in barTop..<h {
                    let o = (y * w + x) * 4
                    px[o + c] = 255
                    px[o + 3] = 255
                }
            }
        }
        return makeImage(&px, w, h)
    }

    private static func renderParade(_ acc: [Float], width pw: Int, height ph: Int) -> CGImage? {
        let w = pw * 3 + 8, h = ph                    // 4px gutter between panels
        var px = [UInt8](repeating: 0, count: w * h * 4)

        var peak: Float = 1
        for v in acc { peak = Swift.max(peak, v) }
        let denom = log(1 + peak)

        for c in 0..<3 {
            let xOffset = c * (pw + 4)
            for y in 0..<ph {
                for x in 0..<pw {
                    let n = acc[(c * ph + y) * pw + x]
                    if n <= 0 { continue }
                    // Log response: a linear one shows only the few densest rows.
                    let t = log(1 + n) / denom
                    let o = (y * w + (x + xOffset)) * 4
                    px[o + c] = UInt8(Swift.min(255, Swift.max(0, t * 255 * 1.6)))
                    px[o + 3] = 255
                }
            }
        }
        return makeImage(&px, w, h)
    }

    /// All three channels on one plot, additively — where they agree the trace
    /// goes white, which is what makes a neutral image instantly readable as
    /// neutral. Normalised against a single shared peak so the channels stay
    /// comparable to each other rather than each being stretched to full range.
    private static func renderCombinedParade(_ acc: [Float], width w: Int, height h: Int) -> CGImage? {
        var px = [UInt8](repeating: 0, count: w * h * 4)

        var peak: Float = 1
        for v in acc { peak = Swift.max(peak, v) }
        let denom = log(1 + peak)

        for y in 0..<h {
            for x in 0..<w {
                var any = false
                let o = (y * w + x) * 4
                for c in 0..<3 {
                    let n = acc[(c * h + y) * w + x]
                    if n <= 0 { continue }
                    any = true
                    let t = log(1 + n) / denom
                    px[o + c] = UInt8(Swift.min(255, Swift.max(0, t * 255 * 1.6)))
                }
                if any { px[o + 3] = 255 }
            }
        }
        return makeImage(&px, w, h)
    }

    private static func renderWaveform(_ acc: [Float], width w: Int, height h: Int) -> CGImage? {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var peak: Float = 1
        for v in acc { peak = Swift.max(peak, v) }
        let denom = log(1 + peak)

        for y in 0..<h {
            for x in 0..<w {
                let n = acc[y * w + x]
                if n <= 0 { continue }
                let t = Swift.min(1, log(1 + n) / denom * 1.7)
                let o = (y * w + x) * 4
                let g = UInt8(t * 235)
                px[o] = UInt8(t * 200); px[o + 1] = g; px[o + 2] = UInt8(t * 210)
                px[o + 3] = 255
            }
        }
        return makeImage(&px, w, h)
    }

    private static func renderCIE(_ acc: [Float], size: Int) -> CGImage? {
        var px = [UInt8](repeating: 0, count: size * size * 4)
        var peak: Float = 1
        for v in acc { peak = Swift.max(peak, v) }
        let denom = log(1 + peak)

        for y in 0..<size {
            for x in 0..<size {
                let n = acc[y * size + x]
                if n <= 0 { continue }
                let t = Swift.min(1, log(1 + n) / denom * 2.0)
                let o = (y * size + x) * 4
                px[o] = UInt8(t * 245); px[o + 1] = UInt8(t * 245); px[o + 2] = UInt8(t * 245)
                px[o + 3] = 255
            }
        }
        return makeImage(&px, size, size)
    }

    private static func renderVectorscope(_ acc: [Float], size: Int) -> CGImage? {
        var px = [UInt8](repeating: 0, count: size * size * 4)
        var peak: Float = 1
        for v in acc { peak = Swift.max(peak, v) }
        let denom = log(1 + peak)

        for y in 0..<size {
            for x in 0..<size {
                let n = acc[y * size + x]
                if n <= 0 { continue }
                let t = Swift.min(1, log(1 + n) / denom * 1.8)
                let o = (y * size + x) * 4
                // Neutral trace; the coloured graticule is drawn by the view.
                px[o] = UInt8(t * 210); px[o + 1] = UInt8(t * 255); px[o + 2] = UInt8(t * 220)
                px[o + 3] = 255
            }
        }
        return makeImage(&px, size, size)
    }

    private static func makeImage(_ px: inout [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes: &px, count: px.count) as CFData)
        else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}
