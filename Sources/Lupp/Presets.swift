import Foundation
import simd

/// A saved grade: everything that changes the pixels, and nothing that changes
/// the window.
///
/// Zoom, panel visibility and window size are deliberately excluded — they are
/// how you were looking at an image, not what you did to it, and restoring them
/// with a preset would move furniture you didn't ask to move.
struct Preset: Codable, Equatable {
    var name: String
    var viewTransform: Int
    var exposureEV: Float
    var lutPath: String?
    var lutAmount: Float
    /// 18 numbers: six corners, RGB each. The order here is this encoding's own
    /// (R Y G C B M) and is only ever read back by `unflatten`; the panel uses
    /// `TetraLayout`'s order. Both address the same named struct fields, so the
    /// two orderings never meet.
    var tetra: [Float]
    var tetraAmount: Float
    var tetraEnabled: Bool
    /// Optional so presets saved before these existed still decode — a missing
    /// key means "the neutral value", which is exactly what it meant then.
    var whiteBalance: [Float]?
    var contrast: Float?
    var contrastPivot: Float?
    var blackPoint: Float?
    var whitePoint: Float?

    static func from(_ d: Renderer.DisplayState, lutPath: String?) -> Preset {
        Preset(name: "",
               viewTransform: d.viewTransform.rawValue,
               exposureEV: d.exposureEV,
               lutPath: lutPath,
               lutAmount: d.lutAmount,
               tetra: Preset.flatten(d.tetra),
               tetraAmount: d.tetraAmount,
               tetraEnabled: d.tetraEnabled,
               whiteBalance: [d.whiteBalance.x, d.whiteBalance.y, d.whiteBalance.z],
               contrast: d.contrast,
               contrastPivot: d.contrastPivot,
               blackPoint: d.blackPoint,
               whitePoint: d.whitePoint)
    }

    /// Applies everything except the LUT, which the caller must load from disk.
    func apply(to d: inout Renderer.DisplayState) {
        d.viewTransform = ViewTransform(rawValue: viewTransform) ?? .standard
        d.exposureEV = exposureEV
        d.lutAmount = lutAmount
        d.tetra = Preset.unflatten(tetra)
        d.tetraAmount = tetraAmount
        d.tetraEnabled = tetraEnabled
        if let w = whiteBalance, w.count == 3 { d.whiteBalance = SIMD3(w[0], w[1], w[2]) }
        else { d.whiteBalance = SIMD3(1, 1, 1) }
        d.contrast = contrast ?? 1
        d.contrastPivot = contrastPivot ?? 0.18
        d.blackPoint = blackPoint ?? 0
        d.whitePoint = whitePoint ?? 1
    }

    static func flatten(_ t: Renderer.TetraCorners) -> [Float] {
        [t.red, t.yellow, t.green, t.cyan, t.blue, t.magenta]
            .flatMap { [$0.x, $0.y, $0.z] }
    }

    static func unflatten(_ v: [Float]) -> Renderer.TetraCorners {
        guard v.count == 18 else { return .identity }
        func c(_ i: Int) -> SIMD4<Float> { SIMD4(v[i * 3], v[i * 3 + 1], v[i * 3 + 2], 0) }
        var t = Renderer.TetraCorners()
        t.red = c(0); t.yellow = c(1); t.green = c(2)
        t.cyan = c(3); t.blue = c(4); t.magenta = c(5)
        return t
    }
}

enum PresetStore {
    private static let key = "presets"
    private static let lastKey = "lastGrade"

    static var all: [Preset] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([Preset].self, from: data) else { return [] }
            return list
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func save(_ p: Preset) {
        var list = all
        // Saving over an existing name replaces it rather than making a twin.
        if let i = list.firstIndex(where: { $0.name == p.name }) { list[i] = p } else { list.append(p) }
        all = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func delete(named name: String) {
        all = all.filter { $0.name != name }
    }

    /// The grade in force when you last changed one, so "Apply Last" can put it
    /// back on an image that opened without it.
    static var last: Preset? {
        get {
            guard let data = UserDefaults.standard.data(forKey: lastKey) else { return nil }
            return try? JSONDecoder().decode(Preset.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: lastKey); return
            }
            UserDefaults.standard.set(data, forKey: lastKey)
        }
    }
}

/// LUTs you've loaded, kept so they can be re-applied without hunting for the
/// file again. Paths only — the cube itself is re-read on use, so editing a LUT
/// on disk takes effect next time rather than serving a stale copy.
enum LUTLibrary {
    private static let key = "lutLibrary"

    static var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func add(_ path: String) {
        var list = paths
        guard !list.contains(path) else { return }
        list.append(path)
        paths = list.sorted {
            ($0 as NSString).lastPathComponent
                .localizedCaseInsensitiveCompare(($1 as NSString).lastPathComponent) == .orderedAscending
        }
    }

    static func remove(_ path: String) {
        paths = paths.filter { $0 != path }
    }

    static func name(for path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
