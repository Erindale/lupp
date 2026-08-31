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

/// What encoding a LUT expects to be fed.
///
/// A creative `.cube` is a lookup with no idea what space its input is in — the
/// author simply assumed one. Get it wrong and the LUT is applied to the wrong
/// numbers, which looks like a bad grade rather than like a mistake.
///
/// A log LUT is almost always a *display rendering*: log in, Rec.709 out. So
/// choosing one here also means the LUT replaces the view transform rather than
/// sitting on top of it — there is no sense in tone-mapping twice.
enum LUTInput: Int, CaseIterable {
    case display = 0     // sRGB-encoded, the usual creative LUT
    case sLog3 = 1
    case logC3 = 2
    case acescct = 3
    case vLog = 4

    var label: String {
        switch self {
        case .display: return "Display (sRGB)"
        case .sLog3:   return "S-Log3"
        case .logC3:   return "LogC3 (ARRI)"
        case .acescct: return "ACEScct"
        case .vLog:    return "V-Log (Panasonic)"
        }
    }

    var isLog: Bool { self != .display }
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
