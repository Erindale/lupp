import Foundation
import ImageIO

/// Everything the file says about itself.
///
/// Read once, at load, on the thread that already went to the disk — asking for
/// it later would mean another trip to a network share to answer a panel that is
/// already on screen.
///
/// Presented as a readable summary first and then the raw truth. EXIF stores
/// most of what a photographer wants as codes and reciprocals: a shutter speed
/// is `0.0004`, a metering mode is `5`. Printing that verbatim is accurate and
/// useless, so the fields worth reading are formatted, and everything else is
/// still listed underneath rather than being quietly dropped.
enum ImageMetadata {

    struct Section {
        let title: String
        let rows: [(String, String)]
    }

    static func read(from url: URL) -> [Section] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { return [] }

        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]

        var sections: [Section] = []

        // MARK: The summary
        var capture: [(String, String)] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { capture.append((label, value)) }
        }
        add("Camera", [tiff["Make"], tiff["Model"]]
            .compactMap { $0 as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces))
        add("Lens", (exif["LensModel"] ?? aux["LensModel"]) as? String)
        add("Shutter", shutter(exif["ExposureTime"]))
        add("Aperture", aperture(exif["FNumber"]))
        add("ISO", (exif["ISOSpeedRatings"] as? [Any])?.first.map { "\($0)" })
        add("Focal length", focal(exif["FocalLength"], equiv: exif["FocalLenIn35mmFilm"]))
        add("Exposure bias", bias(exif["ExposureBiasValue"]))
        add("Taken", (exif["DateTimeOriginal"] as? String).map(readableDate))
        if !capture.isEmpty { sections.append(Section(title: "Capture", rows: capture)) }

        // MARK: Everything else, including the fields above in their raw form
        var file: [(String, String)] = []
        for (k, v) in props.sorted(by: { $0.key < $1.key }) where !(v is [String: Any]) {
            file.append((pretty(k), describe(v)))
        }
        if !file.isEmpty { sections.append(Section(title: "File", rows: file)) }

        for (k, v) in props.sorted(by: { $0.key < $1.key }) {
            guard let dict = v as? [String: Any], !dict.isEmpty else { continue }
            let rows = dict.sorted { $0.key < $1.key }.map { (pretty($0.key), describe($0.value)) }
            sections.append(Section(title: pretty(k), rows: rows))
        }
        return sections
    }

    // MARK: - Making numbers readable

    /// EXIF stores shutter as a fraction of a second, which nobody reads that
    /// way above 1/2s and everybody reads that way below it.
    private static func shutter(_ v: Any?) -> String? {
        guard let t = (v as? NSNumber)?.doubleValue, t > 0 else { return nil }
        if t >= 1 { return String(format: "%.1f s", t) }
        return "1/\(Int((1 / t).rounded())) s"
    }

    /// Zero means the body never learned the aperture — a manual or adapted
    /// lens. Saying "ƒ/0" would be inventing a reading it does not have.
    private static func aperture(_ v: Any?) -> String? {
        guard let f = (v as? NSNumber)?.doubleValue, f > 0 else { return nil }
        return String(format: "ƒ/%.1f", f)
    }

    private static func focal(_ v: Any?, equiv: Any?) -> String? {
        guard let f = (v as? NSNumber)?.doubleValue, f > 0 else { return nil }
        var s = String(format: "%.0f mm", f)
        if let e = (equiv as? NSNumber)?.doubleValue, e > 0, abs(e - f) > 0.5 {
            s += String(format: "  (%.0f mm equiv.)", e)
        }
        return s
    }

    private static func bias(_ v: Any?) -> String? {
        guard let b = (v as? NSNumber)?.doubleValue, abs(b) > 0.001 else { return nil }
        return String(format: "%+.2f EV", b)
    }

    /// EXIF dates are `2026:08:06 18:24:49`, which is nearly but not quite the
    /// way anyone writes one.
    private static func readableDate(_ s: String) -> String {
        let parts = s.split(separator: " ")
        guard parts.count == 2 else { return s }
        return parts[0].replacingOccurrences(of: ":", with: "-") + "  " + parts[1]
    }

    /// `ISOSpeedRatings` reads better as `ISO Speed Ratings`.
    private static func pretty(_ key: String) -> String {
        var out = ""
        for (i, ch) in key.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "").enumerated() {
            if i > 0, ch.isUppercase, let last = out.last, !last.isUppercase {
                out.append(" ")
            }
            out.append(ch)
        }
        return out
    }

    private static func describe(_ v: Any) -> String {
        if let a = v as? [Any] { return a.map { "\($0)" }.joined(separator: ", ") }
        return "\(v)"
    }
}
