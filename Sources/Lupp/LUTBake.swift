import AppKit

/// Writing the grade you built back out as a `.cube`.
///
/// A preset already carries a grade between Lupp's own images, so this is not
/// for that. It is for taking a look somewhere else — Resolve, Premiere, OBS,
/// anything that reads a cube — without rebuilding it by eye in another tool.
enum LUTBake {

    /// 33 is what almost every creative LUT ships as and what most software is
    /// tuned for; 65 is there for a grade with sharp turns in it, at eight times
    /// the file. Beyond that a cube is describing its own interpolation error.
    static let sizes = [17, 33, 65]

    struct Options {
        var name: String
        var size: Int
        var destination: URL?
        var addToLibrary: Bool
    }

    /// The whole colour chain as a cube, or nil if it could not be rendered.
    ///
    /// A renderer of its own, so baking cannot evict the picture on screen.
    static func cube(display: Renderer.DisplayState, lutPath: String?,
                     options: Options) -> String? {
        guard let renderer = Renderer(pixelFormat: .rgba16Float) else { return nil }
        // A LUT already in the grade is part of the grade, so it is baked in too.
        if let lutPath, let lut = try? CubeLUT.parse(url: URL(fileURLWithPath: lutPath)) {
            _ = renderer.loadLUT(lut)
        }
        guard let entries = renderer.bakeLUT(size: options.size, display: display) else {
            return nil
        }

        var out = ""
        out += "# Baked by Lupp from a grade, not measured from footage.\n"
        out += "# Input and output are display-encoded sRGB.\n"
        out += "TITLE \"\(options.name)\"\n"
        out += "LUT_3D_SIZE \(options.size)\n"
        out += "DOMAIN_MIN 0.0 0.0 0.0\n"
        out += "DOMAIN_MAX 1.0 1.0 1.0\n"
        for e in entries {
            out += String(format: "%.6f %.6f %.6f\n", e.x, e.y, e.z)
        }
        return out
    }

    /// What the grade contains that a cube cannot carry, in the user's terms.
    ///
    /// Said before writing rather than discovered afterwards: a LUT that quietly
    /// dropped half your work would look like the grade simply not surviving the
    /// trip to another tool.
    static func caveats(for d: Renderer.DisplayState, sceneLinear: Bool) -> [String] {
        var notes: [String] = []
        if d.cropEnabled {
            notes.append("The crop isn’t included — a cube maps colours and has no geometry.")
        }
        if sceneLinear {
            notes.append("This image is scene-linear, so values above white have nowhere to go in a 0–1 cube. The look will be right for display-referred footage.")
        }
        if d.lutOn, d.lutName != nil, d.lutInput != .display {
            notes.append("The loaded LUT expects log input and stands in for the view transform; baked into a display-referred cube it is an approximation.")
        }
        if d.channel != .rgb || d.showClipping || d.falseColour {
            notes.append("Channel isolation and the clipping and false-colour overlays are left out — they describe the picture rather than change it.")
        }
        return notes
    }
}

/// The sheet that asks how the cube should be named, how fine it should be, and
/// where it should go.
final class LUTBakeSheet: NSObject {
    private let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
                                 styleMask: [.titled], backing: .buffered, defer: false)
    private let nameField = NSTextField(string: "")
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let libraryCheck = NSButton(checkboxWithTitle: "Also add to Lupp’s LUT library",
                                        target: nil, action: nil)
    private let destLabel = ThemedLabel("Choose a folder…", role: .secondary, size: 11)
    private var destination: URL?
    private var onRun: ((LUTBake.Options) -> Void)?
    private let caveats: [String]

    init(suggestedName: String, caveats: [String]) {
        self.caveats = caveats
        super.init()
        nameField.stringValue = suggestedName
    }

    func present(over host: NSWindow, run: @escaping (LUTBake.Options) -> Void) {
        onRun = run
        panel.title = "Export Grade as LUT"

        nameField.placeholderString = "Grade name"
        for s in LUTBake.sizes {
            sizePopup.addItem(withTitle: "\(s)³" + (s == 33 ? "  (standard)" : ""))
            sizePopup.lastItem?.tag = s
        }
        sizePopup.selectItem(withTag: 33)
        // Ticked by default: the common case is wanting it in Lupp too, and the
        // library copy is the one that survives tidying your Downloads folder.
        libraryCheck.state = .on

        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseDestination))
        choose.bezelStyle = .rounded
        choose.controlSize = .small

        let go = NSButton(title: "Export", target: self, action: #selector(export))
        go.bezelStyle = .rounded
        go.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        func row(_ label: String, _ control: NSView) -> NSStackView {
            let l = ThemedLabel(label, role: .tertiary, size: 11)
            l.alignment = .right
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let r = NSStackView(views: [l, control])
            r.orientation = .horizontal
            r.spacing = 10
            return r
        }

        let dest = NSStackView(views: [destLabel, choose])
        dest.orientation = .horizontal
        dest.spacing = 8
        let buttons = NSStackView(views: [NSView(), cancel, go])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        var views: [NSView] = [row("Name", nameField), row("Size", sizePopup),
                               row("Folder", dest), row("", libraryCheck)]
        for note in caveats {
            let l = ThemedLabel("• " + note, role: .tertiary, size: 10)
            l.lineBreakMode = .byWordWrapping
            l.maximumNumberOfLines = 0
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 420).isActive = true
            views.append(l)
        }
        views.append(buttons)

        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            nameField.widthAnchor.constraint(equalToConstant: 220),
            buttons.widthAnchor.constraint(equalToConstant: 420),
        ])
        panel.contentView = content
        host.beginSheet(panel)
    }

    @objc private func chooseDestination() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = "Where should the .cube file go?"
        guard p.runModal() == .OK, let url = p.url else { return }
        destination = url
        destLabel.stringValue = url.lastPathComponent
        destLabel.applyTheme()
    }

    @objc private func export() {
        let name = nameField.stringValue.isEmpty ? "Lupp Grade" : nameField.stringValue
        // Somewhere has to be chosen, unless the library is the destination.
        guard destination != nil || libraryCheck.state == .on else {
            let a = NSAlert()
            a.messageText = "Nowhere to put it"
            a.informativeText = "Choose a folder, or tick “Also add to Lupp’s LUT library”."
            a.beginSheetModal(for: panel) { _ in }
            return
        }
        close()
        onRun?(LUTBake.Options(name: name, size: sizePopup.selectedTag(),
                               destination: destination,
                               addToLibrary: libraryCheck.state == .on))
    }

    @objc func close() {
        panel.sheetParent?.endSheet(panel)
    }
}
