import Foundation

/// What tone mapping stands between the file's values and the screen.
///
/// A file records its *colour space* and Lupp reads that automatically. It does
/// not record a *view transform* — Blender doesn't write "I was rendered through
/// AgX" into an EXR — so for scene-linear sources this is a choice, defaulted
/// from what the file is and overridable in the panel.
enum ViewTransform: Int, CaseIterable {
    case standard = 0     // inverse sRGB EOTF only; correct for display-referred files
    case agx = 1
    case acesFilmic = 2
    case raw = 3          // no tone map, hard clip — see the data, not a look

    var label: String {
        switch self {
        case .standard:   return "Standard"
        case .agx:        return "AgX"
        case .acesFilmic: return "ACES Filmic"
        case .raw:        return "Raw"
        }
    }

    var detail: String {
        switch self {
        case .standard:   return "Inverse sRGB only. Right for images that are already graded."
        case .agx:        return "Approximates Blender 4.x's default view transform."
        case .acesFilmic: return "Narkowicz/Hill RRT+ODT fit, not the reference ACES LUTs."
        case .raw:        return "No tone map. Values above 1.0 clip hard."
        }
    }

    /// Scene-linear files carry no look of their own and blow out under a plain
    /// sRGB encode; display-referred files are already graded and must not be
    /// tone-mapped twice.
    static func detected(for image: FloatImage) -> ViewTransform {
        image.isSceneLinear ? .agx : .standard
    }
}

/// Which channel reaches the screen.
enum ChannelView: Int, CaseIterable {
    case rgb = 0, red, green, blue, alpha, luma

    var label: String {
        switch self {
        case .rgb:   return "RGB"
        case .red:   return "R"
        case .green: return "G"
        case .blue:  return "B"
        case .alpha: return "A"
        case .luma:  return "L"
        }
    }
}
