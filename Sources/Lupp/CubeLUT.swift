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

    /// Parsed LUTs, keyed by path and the file's modification time and size.
    ///
    /// Re-parsing a 64³ cube costs tens of milliseconds and re-reading it from
    /// disk costs one, so switching between library entries should be free. Keyed
    /// on mtime and size rather than path alone, so editing a LUT on disk still
    /// takes effect — the cache never serves a stale cube.
    private static var cache: [String: (stamp: String, lut: CubeLUT)] = [:]

    static func parse(url: URL) throws -> CubeLUT {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = "\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            + "-\((attrs?[.size] as? Int) ?? 0)"
        if let hit = cache[url.path], hit.stamp == stamp { return hit.lut }

        let lut = try parseUncached(url: url)
        cache[url.path] = (stamp, lut)
        return lut
    }

    /// Parsed over the raw bytes rather than over Swift strings.
    ///
    /// A 64³ cube is 262,144 data lines. Splitting that into strings and then
    /// into fields allocates the better part of a million objects and took over
    /// 400ms — nearly all of the delay in applying a LUT, since reading the file
    /// itself takes one. Scanning bytes and handing the numbers to `strtof` does
    /// the same work without allocating anything per line.
    private static func parseUncached(url: URL) throws -> CubeLUT {
        guard var data = try? Data(contentsOf: url) else { throw ParseError.unreadable(url) }
        data.append(0)          // strtof needs somewhere definite to stop

        var title = url.deletingPathExtension().lastPathComponent
        var size3D: Int?
        var size1D: Int?
        var dMin = SIMD3<Float>(0, 0, 0)
        var dMax = SIMD3<Float>(1, 1, 1)
        var values: [SIMD3<Float>] = []
        values.reserveCapacity(1 << 18)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            let count = raw.count - 1
            var i = 0

            func isSpace(_ c: CChar) -> Bool { c == 32 || c == 9 || c == 13 }
            func isDigitish(_ c: CChar) -> Bool {
                (c >= 48 && c <= 57) || c == 45 || c == 43 || c == 46
            }

            while i < count {
                while i < count, isSpace(base[i]) { i += 1 }
                guard i < count else { break }
                let c = base[i]

                if c == 10 { i += 1; continue }

                if isDigitish(c) {
                    var p: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer(mutating: base + i)
                    var v = SIMD3<Float>(0, 0, 0)
                    var ok = true
                    for k in 0..<3 {
                        let start = p
                        let f = strtof(p!, &p)
                        if p == start { ok = false; break }
                        v[k] = f
                    }
                    if ok { values.append(v) }
                    // Skip to the end of the line either way.
                    while i < count, base[i] != 10 { i += 1 }
                    continue
                }

                // A keyword or a comment: take the line as text, there are few.
                let lineStart = i
                while i < count, base[i] != 10 { i += 1 }
                let line = String(decoding: UnsafeRawBufferPointer(
                    start: base + lineStart, count: i - lineStart), as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") { continue }

                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard let keyword = parts.first?.uppercased() else { continue }
                switch keyword {
                case "TITLE":
                    let quoted = line.drop(while: { $0 != "\"" })
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !quoted.isEmpty { title = quoted }
                case "LUT_3D_SIZE": size3D = parts.count > 1 ? Int(parts[1]) : nil
                case "LUT_1D_SIZE": size1D = parts.count > 1 ? Int(parts[1]) : nil
                case "DOMAIN_MIN":
                    if parts.count >= 4 {
                        dMin = SIMD3(Float(parts[1]) ?? 0, Float(parts[2]) ?? 0, Float(parts[3]) ?? 0)
                    }
                case "DOMAIN_MAX":
                    if parts.count >= 4 {
                        dMax = SIMD3(Float(parts[1]) ?? 1, Float(parts[2]) ?? 1, Float(parts[3]) ?? 1)
                    }
                case "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE":
                    if parts.count >= 3, let lo = Float(parts[1]), let hi = Float(parts[2]) {
                        dMin = SIMD3(repeating: lo)
                        dMax = SIMD3(repeating: hi)
                    }
                default: break
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
                        cube.append(SIMD3(values[r * (n - 1) / (m - 1)].x,
                                          values[g * (n - 1) / (m - 1)].y,
                                          values[b * (n - 1) / (m - 1)].z))
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
