import AppKit
import Foundation
import simd

/// A saved editing session: which image, and everything done to it.
///
/// The image is referenced, not embedded. A session sitting beside a 200MB EXR
/// should be a few kilobytes of numbers, and the point is to reopen *that* file
/// with the work still live and every control still movable — not to freeze a
/// result. Nothing here is destructive; the source is never written to.
///
/// Both a path and a bookmark are stored. The path is what a human can read and
/// fix in a text editor; the bookmark is what still finds the file after it has
/// been moved or renamed.
struct Session: Codable {
    static let fileExtension = "lupp"
    /// Sessions written before the extension was shortened still open.
    static let legacyExtensions = ["luppsession"]
    static let typeIdentifier = "xyz.nodegroup.lupp.session"

    var version = 1
    var imagePath: String
    var bookmark: Data?

    // Grade
    var viewTransform: Int
    var exposureEV: Float
    var whiteBalance: [Float]
    var contrast: Float
    var contrastPivot: Float
    var blackPoint: Float
    var whitePoint: Float
    /// Eighteen corner values, in the same order `Preset` uses.
    var tetra: [Float]
    var tetraAmount: Float
    var tetraActive: Bool
    /// Optional so sessions written before saturation existed still open.
    var saturation: Float?
    var saturationOn: Bool?

    var lutPath: String?
    var lutAmount: Float
    var lutInput: Int

    // Crop
    var crop: [Float]
    var cropEnabled: Bool
    var cropApplied: Bool

    // Bypasses — a session should reopen bypassed if that is how you left it.
    var gradeEnabled: Bool
    var lightOn: Bool
    var whiteBalanceOn: Bool
    var tetraOn: Bool
    var lutOn: Bool

    // Inspection state, which is part of how you were looking at it.
    var channel: Int
    var showClipping: Bool
    var falseColour: Bool

    // MARK: - Making one

    static func from(_ d: Renderer.DisplayState, image: URL, lutPath: String?) -> Session {
        Session(imagePath: image.path,
                bookmark: try? image.bookmarkData(options: .minimalBookmark,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil),
                viewTransform: d.viewTransform.rawValue,
                exposureEV: d.exposureEV,
                whiteBalance: [d.whiteBalance.x, d.whiteBalance.y, d.whiteBalance.z],
                contrast: d.contrast,
                contrastPivot: d.contrastPivot,
                blackPoint: d.blackPoint,
                whitePoint: d.whitePoint,
                tetra: Preset.flatten(d.tetra),
                tetraAmount: d.tetraAmount,
                tetraActive: d.tetraActive,
                saturation: d.saturation,
                saturationOn: d.saturationOn,
                lutPath: lutPath,
                lutAmount: d.lutAmount,
                lutInput: d.lutInput.rawValue,
                crop: [d.crop.x, d.crop.y, d.crop.z, d.crop.w],
                cropEnabled: d.cropEnabled,
                cropApplied: d.cropApplied,
                gradeEnabled: d.gradeEnabled,
                lightOn: d.lightOn,
                whiteBalanceOn: d.whiteBalanceOn,
                tetraOn: d.tetraOn,
                lutOn: d.lutOn,
                channel: d.channel.rawValue,
                showClipping: d.showClipping,
                falseColour: d.falseColour)
    }

    /// Everything except the LUT, which the caller loads from disk.
    func apply(to d: inout Renderer.DisplayState) {
        d.viewTransform = ViewTransform(rawValue: viewTransform) ?? .standard
        d.exposureEV = exposureEV
        if whiteBalance.count == 3 {
            d.whiteBalance = SIMD3(whiteBalance[0], whiteBalance[1], whiteBalance[2])
        }
        d.contrast = contrast
        d.contrastPivot = contrastPivot
        d.blackPoint = blackPoint
        d.whitePoint = whitePoint
        d.tetra = Preset.unflatten(tetra)
        d.tetraAmount = tetraAmount
        d.tetraActive = tetraActive
        if let saturation { d.saturation = saturation }
        if let saturationOn { d.saturationOn = saturationOn }
        d.lutAmount = lutAmount
        d.lutInput = LUTInput(rawValue: lutInput) ?? .display
        if crop.count == 4 { d.crop = SIMD4(crop[0], crop[1], crop[2], crop[3]) }
        d.cropEnabled = cropEnabled
        d.cropApplied = cropApplied
        d.gradeEnabled = gradeEnabled
        d.lightOn = lightOn
        d.whiteBalanceOn = whiteBalanceOn
        d.tetraOn = tetraOn
        d.lutOn = lutOn
        d.channel = ChannelView(rawValue: channel) ?? .rgb
        d.showClipping = showClipping
        d.falseColour = falseColour
    }

    // MARK: - Finding the image again

    enum ResolveResult {
        case found(URL)
        case moved(URL)        // the bookmark found it somewhere else
        case missing(String)
    }

    /// Point the session at a different file, keeping everything else.
    mutating func relocate(to url: URL) {
        imagePath = url.path
        bookmark = try? url.bookmarkData(options: .minimalBookmark,
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
    }

    /// Path first, because it is the one a person can reason about; bookmark
    /// second, because it is the one that survives a move.
    func resolveImage() -> ResolveResult {
        if FileManager.default.fileExists(atPath: imagePath) {
            return .found(URL(fileURLWithPath: imagePath))
        }
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return .moved(url)
            }
        }
        return .missing(imagePath)
    }

    // MARK: - Disk

    func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> Session {
        try JSONDecoder().decode(Session.self, from: Data(contentsOf: url))
    }

    static func isSession(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return e == fileExtension || legacyExtensions.contains(e)
    }
}
