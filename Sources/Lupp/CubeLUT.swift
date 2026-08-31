import Foundation
import simd

/// A parsed Adobe/IRIDAS `.cube` LUT, ready to become a 3D texture.
struct CubeLUT {
    let title: String
    let size: Int
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>
    /// RGBA float, `size³` entries, red varying fastest — the order the format
    /// specifies and the order a Metal 3D texture wants.
    let rgba: [Float]
    let wasOneDimensional: Bool

    /// A 1D LUT is expanded into a 3D one so a single sampling path serves both.
    /// Capped, because expanding a 1024-entry 1D LUT literally would ask for a
    /// billion texels to express what is really three curves.
    private static let maxExpandedSize = 64
    private static let maxSize = 128

    enum ParseError: LocalizedError {
        case noSize(URL)
        case badSize(Int)
        case shortData(expected: Int, got: Int)
        case unreadable(URL)

        var errorDescription: String? {
            switch self {
            case .noSize(let u):
                return "\(u.lastPathComponent) declares neither LUT_3D_SIZE nor LUT_1D_SIZE."
            case .badSize(let n):
                return "LUT size \(n) is out of range (2–\(maxSize))."
            case .shortData(let e, let g):
                return "Expected \(e) LUT entries but found \(g)."
            case .unreadable(let u):
                return "Couldn’t read \(u.lastPathComponent)."
            }
        }
    }

    static func parse(url: URL) throws -> CubeLUT {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ParseError.unreadable(url)
        }

        var title = url.deletingPathExtension().lastPathComponent
        var size3D: Int?
        var size1D: Int?
        var dMin = SIMD3<Float>(0, 0, 0)
        var dMax = SIMD3<Float>(1, 1, 1)
        var values: [SIMD3<Float>] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let keyword = parts.first else { continue }

            switch keyword.uppercased() {
            case "TITLE":
                title = line.drop(while: { $0 != "\"" }).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
            case "LUT_3D_SIZE":
                size3D = parts.count > 1 ? Int(parts[1]) : nil
            case "LUT_1D_SIZE":
                size1D = parts.count > 1 ? Int(parts[1]) : nil
            case "DOMAIN_MIN":
                if parts.count >= 4 { dMin = SIMD3(Float(parts[1]) ?? 0, Float(parts[2]) ?? 0, Float(parts[3]) ?? 0) }
            case "DOMAIN_MAX":
                if parts.count >= 4 { dMax = SIMD3(Float(parts[1]) ?? 1, Float(parts[2]) ?? 1, Float(parts[3]) ?? 1) }
            case "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE":
                if parts.count >= 3, let lo = Float(parts[1]), let hi = Float(parts[2]) {
                    dMin = SIMD3(repeating: lo)
                    dMax = SIMD3(repeating: hi)
                }
            default:
                // A data row: three floats and nothing else.
                if parts.count >= 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) {
                    values.append(SIMD3(r, g, b))
                }
            }
        }

        if let n = size3D {
            guard n >= 2, n <= maxSize else { throw ParseError.badSize(n) }
            let expected = n * n * n
            guard values.count >= expected else {
                throw ParseError.shortData(expected: expected, got: values.count)
            }
            return CubeLUT(title: title, size: n, domainMin: dMin, domainMax: dMax,
                           rgba: pack(values, count: expected), wasOneDimensional: false)
        }

        if let n = size1D {
            guard n >= 2 else { throw ParseError.badSize(n) }
            guard values.count >= n else {
                throw ParseError.shortData(expected: n, got: values.count)
            }
            let m = min(n, maxExpandedSize)
            var cube: [SIMD3<Float>] = []
            cube.reserveCapacity(m * m * m)
            // Each axis is looked up independently — that is what makes it 1D.
            for b in 0..<m {
                for g in 0..<m {
                    for r in 0..<m {
                        let sr = values[r * (n - 1) / (m - 1)].x
                        let sg = values[g * (n - 1) / (m - 1)].y
                        let sb = values[b * (n - 1) / (m - 1)].z
                        cube.append(SIMD3(sr, sg, sb))
                    }
                }
            }
            return CubeLUT(title: title, size: m, domainMin: dMin, domainMax: dMax,
                           rgba: pack(cube, count: cube.count), wasOneDimensional: true)
        }

        throw ParseError.noSize(url)
    }

    private static func pack(_ v: [SIMD3<Float>], count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count * 4)
        for i in 0..<count {
            out[i * 4] = v[i].x
            out[i * 4 + 1] = v[i].y
            out[i * 4 + 2] = v[i].z
            out[i * 4 + 3] = 1
        }
        return out
    }
}
