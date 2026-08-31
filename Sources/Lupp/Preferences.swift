import AppKit
import Foundation

enum Preferences {
    private static let scrollZoomKey = "scrollWheelZooms"

    /// Default on, because "scroll to zoom" is the point of the app. The toggle
    /// exists because no heuristic for telling a mouse from a trackpad is perfect
    /// — third-party drivers reshape the events — and one menu click should be
    /// enough to fix it permanently when the guess is wrong.
    static var scrollWheelZooms: Bool {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: scrollZoomKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: scrollZoomKey) }
    }

    /// Remembered so the panels stay where you left them between launches.
    static var scopesPanelOpen: Bool {
        get { UserDefaults.standard.bool(forKey: "scopesPanelOpen") }
        set { UserDefaults.standard.set(newValue, forKey: "scopesPanelOpen") }
    }

    static var gradePanelOpen: Bool {
        get { UserDefaults.standard.bool(forKey: "gradePanelOpen") }
        set { UserDefaults.standard.set(newValue, forKey: "gradePanelOpen") }
    }

    /// The view transform is re-detected per image, but an override sticks — kept
    /// per *class* of file so choosing ACES for one EXR still applies to the next
    /// one, without leaking that choice onto a JPEG that needs no tone map.
    static func viewTransform(sceneLinear: Bool) -> ViewTransform {
        let key = sceneLinear ? "viewTransformSceneLinear" : "viewTransformDisplayReferred"
        guard let raw = UserDefaults.standard.object(forKey: key) as? Int,
              let t = ViewTransform(rawValue: raw) else {
            return sceneLinear ? .agx : .standard
        }
        return t
    }

    static func setViewTransform(_ t: ViewTransform, sceneLinear: Bool) {
        let key = sceneLinear ? "viewTransformSceneLinear" : "viewTransformDisplayReferred"
        UserDefaults.standard.set(t.rawValue, forKey: key)
    }

    /// The export format you chose last, so the panel opens on it again.
    static var lastExportExtension: String {
        get { UserDefaults.standard.string(forKey: "lastExportExtension") ?? "png" }
        set { UserDefaults.standard.set(newValue, forKey: "lastExportExtension") }
    }

    /// What encoding the LUT is fed. Sticky, because a given user's LUTs almost
    /// always come from the same camera.
    static var lutInput: Int {
        get { UserDefaults.standard.integer(forKey: "lutInput") }
        set { UserDefaults.standard.set(newValue, forKey: "lutInput") }
    }

    /// Canvas and chrome backdrop, in sRGB.
    static var backgroundLevel: CGFloat {
        get {
            guard let v = UserDefaults.standard.object(forKey: "backgroundLevel") as? Double
            else { return Theme.defaultBackgroundSRGB }
            return CGFloat(v)
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "backgroundLevel") }
    }

    /// Flips scroll-zoom direction. Present because no amount of reasoning about
    /// `isDirectionInvertedFromDevice` settles what a given mouse and driver
    /// combination will actually send — this makes it one click to correct.
    static var invertScrollZoom: Bool {
        get { UserDefaults.standard.bool(forKey: "invertScrollZoom") }
        set { UserDefaults.standard.set(newValue, forKey: "invertScrollZoom") }
    }

    /// How large the interface is drawn. 1.0 is the design size.
    ///
    /// Clamped on read rather than only on write, so a value typed straight into
    /// the defaults plist can't produce a window with no usable controls in it.
    static let uiScaleRange: ClosedRange<CGFloat> = 0.8...1.6

    static var uiScale: CGFloat {
        get {
            guard let v = UserDefaults.standard.object(forKey: "uiScale") as? Double
            else { return 1 }
            return min(max(CGFloat(v), uiScaleRange.lowerBound), uiScaleRange.upperBound)
        }
        set {
            let v = min(max(newValue, uiScaleRange.lowerBound), uiScaleRange.upperBound)
            UserDefaults.standard.set(Double(v), forKey: "uiScale")
        }
    }

    /// Which waveform the parade scope shows: 0 parade, 1 combined, 2 luma.
    /// One scope with three modes rather than three scopes, as Resolve does it.
    static var paradeMode: Int {
        get { UserDefaults.standard.integer(forKey: "paradeMode") }
        set { UserDefaults.standard.set(newValue, forKey: "paradeMode") }
    }

    /// Windows share one autosaved frame, so a new image opens at whatever size
    /// you were last working at and scales to fit it — rather than the window
    /// jumping to the image's dimensions every time you open a bigger file.
    static let windowFrameAutosaveName = "LuppViewer"

    /// AppKit's own key for the above. Checked to tell a first run (size the
    /// window to the image) from every run after (keep the user's size).
    static var hasSavedWindowFrame: Bool {
        UserDefaults.standard.string(forKey: "NSWindow Frame \(windowFrameAutosaveName)") != nil
    }

    /// `LUPP_DEBUG=1` prints what each scroll event actually looked like, which is
    /// the only way to diagnose an input device that lies about what it is.
    static let debug = ProcessInfo.processInfo.environment["LUPP_DEBUG"] == "1"

    static func logScroll(_ e: NSEvent, isTrackpad: Bool, zooming: Bool) {
        guard debug else { return }
        FileHandle.standardError.write(String(
            format: "scroll precise=%d phase=%lu momentum=%lu inverted=%d dx=%.2f dy=%.2f -> %@ (%@)\n",
            e.hasPreciseScrollingDeltas ? 1 : 0,
            e.phase.rawValue, e.momentumPhase.rawValue,
            e.isDirectionInvertedFromDevice ? 1 : 0,
            e.scrollingDeltaX, e.scrollingDeltaY,
            zooming ? "ZOOM" : "pan",
            isTrackpad ? "trackpad" : "mouse").data(using: .utf8)!)
    }
}
