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
    /// Optional so presets saved before saturation existed still load.
    var saturation: Float?
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
               saturation: d.saturation,
               tetraEnabled: d.tetraActive,
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
        d.saturation = saturation ?? 1
        d.tetraActive = tetraEnabled
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
            // Flushed rather than left to the periodic write: presets are work,
            // and a force-quit shortly after saving one shouldn't lose it.
            UserDefaults.standard.synchronize()
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

/// LUTs you've added, copied into the app's own storage.
///
/// Copied rather than referenced: a library that points at wherever the file
/// happened to be when you added it breaks the moment you tidy your Downloads
/// folder, and does it silently. The copy is the app's, so removing an entry
/// deletes it.
enum LUTLibrary {
    private static let key = "lutLibrary"

    /// `~/Library/Application Support/Lupp/LUTs`
    static var storeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("Lupp/LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func isInStore(_ path: String) -> Bool {
        path.hasPrefix(storeDirectory.path + "/")
    }

    static var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            UserDefaults.standard.synchronize()
        }
    }

    /// Copies the file in and returns where it now lives, or the original path if
    /// the copy failed — better a working reference than a missing LUT.
    @discardableResult
    static func add(importing url: URL) -> String {
        if isInStore(url.path) { register(url.path); return url.path }

        let dir = storeDirectory
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        // Same name, different file: keep both rather than overwriting someone's
        // LUT with a namesake.
        if FileManager.default.fileExists(atPath: dest.path),
           !sameContents(url, dest) {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var n = 2
            repeat {
                dest = dir.appendingPathComponent("\(stem) \(n).\(ext)")
                n += 1
            } while FileManager.default.fileExists(atPath: dest.path) && n < 100
        }

        if !FileManager.default.fileExists(atPath: dest.path) {
            do { try FileManager.default.copyItem(at: url, to: dest) }
            catch {
                register(url.path)
                return url.path
            }
        }
        register(dest.path)
        return dest.path
    }

    private static func sameContents(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        let sa = (try? fm.attributesOfItem(atPath: a.path)[.size] as? Int) ?? nil
        let sb = (try? fm.attributesOfItem(atPath: b.path)[.size] as? Int) ?? nil
        return sa != nil && sa == sb
    }

    private static func register(_ path: String) {
        var list = paths
        guard !list.contains(path) else { return }
        list.append(path)
        paths = list.sorted {
            ($0 as NSString).lastPathComponent
                .localizedCaseInsensitiveCompare(($1 as NSString).lastPathComponent) == .orderedAscending
        }
    }

    /// Removing an entry deletes the app's copy — it is ours, and leaving orphans
    /// in Application Support is just a slower version of the mess this avoids.
    /// Anything still pointing outside the store is only forgotten, never deleted.
    static func remove(_ path: String) {
        paths = paths.filter { $0 != path }
        if isInStore(path) { try? FileManager.default.removeItem(atPath: path) }
    }

    /// Brings entries added before the store existed inside it, so the promise
    /// holds for LUTs already in the library.
    static func migrateStrays() {
        for path in paths where !isInStore(path) {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                paths = paths.filter { $0 != path }
                continue
            }
            let moved = add(importing: url)
            if moved != path { paths = paths.filter { $0 != path } }
        }
    }

    static func name(for path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
