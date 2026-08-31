import CoreGraphics
import Foundation

/// CIE 1931 chromaticity reference data for the xy scope.
enum CIE {
    static let size = 256

    /// Plot bounds — deliberately equal on both axes.
    ///
    /// A chromaticity diagram has to be isotropic: one unit of x and one unit of y
    /// must measure the same on screen, or the locus is drawn stretched and the
    /// gamut triangles misrepresent their own shapes. Using different ranges for
    /// the two axes inside a square plot did exactly that. The locus peaks at
    /// x≈0.735, y≈0.834, so a common 0.85 contains it with room to spare.
    static let axisMax = 0.85
    static var xMax: Double { axisMax }
    static var yMax: Double { axisMax }

    static let d65 = CGPoint(x: 0.3127, y: 0.3290)

    struct Gamut {
        let name: String
        let red, green, blue: CGPoint
    }

    /// sRGB and Rec.709 share primaries, so one triangle covers both.
    static let gamuts: [Gamut] = [
        Gamut(name: "709", red: CGPoint(x: 0.640, y: 0.330),
              green: CGPoint(x: 0.300, y: 0.600), blue: CGPoint(x: 0.150, y: 0.060)),
        Gamut(name: "P3", red: CGPoint(x: 0.680, y: 0.320),
              green: CGPoint(x: 0.265, y: 0.690), blue: CGPoint(x: 0.150, y: 0.060)),
        Gamut(name: "2020", red: CGPoint(x: 0.708, y: 0.292),
              green: CGPoint(x: 0.170, y: 0.797), blue: CGPoint(x: 0.131, y: 0.046)),
    ]

    /// The spectral locus, from the multi-lobe Gaussian fit to the CIE 1931 2°
    /// colour matching functions (Wyman, Sloan & Shirley, JCGT 2013).
    ///
    /// An analytic fit rather than the tabulated observer: accurate to about a
    /// percent, which is far below the width of the line it draws, and it keeps
    /// a few hundred numbers out of the source.
    static let spectralLocus: [CGPoint] = {
        func lobe(_ w: Double, _ mu: Double, _ s1: Double, _ s2: Double) -> Double {
            let t = (w - mu) * (w < mu ? s1 : s2)
            return exp(-0.5 * t * t)
        }
        func xBar(_ w: Double) -> Double {
            0.362 * lobe(w, 442.0, 0.0624, 0.0374)
            + 1.056 * lobe(w, 599.8, 0.0264, 0.0323)
            - 0.065 * lobe(w, 501.1, 0.0490, 0.0382)
        }
        func yBar(_ w: Double) -> Double {
            0.821 * lobe(w, 568.8, 0.0213, 0.0247)
            + 0.286 * lobe(w, 530.9, 0.0613, 0.0322)
        }
        func zBar(_ w: Double) -> Double {
            1.217 * lobe(w, 437.0, 0.0845, 0.0278)
            + 0.681 * lobe(w, 459.0, 0.0385, 0.0725)
        }

        // Start at 400nm, not 380. Below that every colour matching function is
        // near zero, so X/(X+Y+Z) is a ratio of noise and the points scatter —
        // which showed up as a tangle at the foot of the diagram and a closing
        // chord running to a garbage endpoint. The locus barely moves between
        // 380 and 400nm, so nothing visible is lost.
        var pts: [CGPoint] = []
        var w = 400.0
        while w <= 700.0 {
            let X = xBar(w), Y = yBar(w), Z = zBar(w)
            let s = X + Y + Z
            guard s > 1e-4 else { w += 1; continue }
            let p = CGPoint(x: X / s, y: Y / s)
            // The analytic fit has a small negative lobe; discard anything it
            // pushes outside the region a chromaticity can occupy.
            if p.x >= 0, p.y >= 0, p.x <= axisMax, p.y <= axisMax { pts.append(p) }
            w += 1
        }

        // The spectral locus plus the line of purples is precisely the convex
        // hull of the spectral points, so taking the hull both closes the shape
        // correctly and drops any stray point the fit produced.
        return convexHull(pts)
    }()

    /// Andrew's monotone chain.
    private static func convexHull(_ input: [CGPoint]) -> [CGPoint] {
        guard input.count > 2 else { return input }
        let pts = input.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }
}
