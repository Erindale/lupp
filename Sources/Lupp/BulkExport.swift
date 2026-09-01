import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Writing out every image you edited, in one go.
///
/// The workflow this exists for is running a folder of photographs, applying a
/// preset or a quick grade to each, and then wanting all of it on disk without
/// visiting every frame a second time. Each image is rendered through the same
/// shader the canvas uses, from the work cached against it — so what lands in
/// the folder is what you saw when you graded it.
enum BulkExport {

    struct Options {
        var suffix: String
        var format: ExportFormatAccessory.Format
        /// Nil means "beside the original", which is what a per-image suffix is
        /// for. A folder means everything lands together.
        var destination: URL?
    }

    struct Outcome {
        var written: [URL] = []
        var failed: [(URL, String)] = []
        var skipped: [URL] = []
    }

    /// Where one image's export will land.
    static func destination(for source: URL, options: Options) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let name = options.suffix.isEmpty ? stem : "\(stem)_\(options.suffix)"
        let folder = options.destination ?? source.deletingLastPathComponent()
        return folder.appendingPathComponent(name).appendingPathExtension(options.format.ext)
    }

    /// Render and write every edit.
    ///
    /// Runs off the main thread — each image has to be decoded and rendered, and
    /// on a network share the decode alone is the best part of a second. The
    /// renderer is built here rather than borrowed from the window: a second one
    /// costs a few milliseconds and keeps a long batch off the canvas's own
    /// device queue, so the window stays usable while it runs.
    static func run(edits: [URL: Session], options: Options,
                    progress: @escaping (Int, Int) -> Void,
                    finished: @escaping (Outcome) -> Void) {
        let jobs = edits.sorted { $0.key.path < $1.key.path }
        DispatchQueue.global(qos: .userInitiated).async {
            var outcome = Outcome()
            guard let renderer = Renderer(pixelFormat: .rgba16Float) else {
                DispatchQueue.main.async {
                    outcome.failed = jobs.map { ($0.key, "Metal is unavailable.") }
                    finished(outcome)
                }
                return
            }

            for (i, job) in jobs.enumerated() {
                let (url, session) = job
                DispatchQueue.main.async { progress(i, jobs.count) }

                let out = destination(for: url, options: options)
                // Never write over something already there. A batch that quietly
                // replaced a file you had exported earlier would be the worst
                // kind of convenience.
                if FileManager.default.fileExists(atPath: out.path) {
                    outcome.skipped.append(out)
                    continue
                }
                guard let img = try? ImageLoader.load(url: url) else {
                    outcome.failed.append((url, "couldn’t be read"))
                    continue
                }
                var d = Renderer.DisplayState()
                session.apply(to: &d)
                // The LUT is loaded per image because two frames may not share
                // one, and the parser caches by path so this is nearly free.
                if let path = session.lutPath, let lut = try? CubeLUT.parse(
                    url: URL(fileURLWithPath: path)) {
                    _ = renderer.loadLUT(lut)
                } else {
                    renderer.clearLUT()
                }
                renderer.upload(img)

                let size = CGSize(width: img.width, height: img.height)
                guard let cg = renderer.exportImage(size: size, display: d,
                                                    bitDepth: options.format.bitDepth),
                      let dest = CGImageDestinationCreateWithURL(
                        out as CFURL, options.format.type.identifier as CFString, 1, nil) else {
                    outcome.failed.append((url, "couldn’t be rendered"))
                    continue
                }
                var props: [CFString: Any] = [:]
                if options.format == .jpeg {
                    props[kCGImageDestinationLossyCompressionQuality] = 0.95
                }
                CGImageDestinationAddImage(dest, cg, props as CFDictionary)
                if CGImageDestinationFinalize(dest) {
                    outcome.written.append(out)
                } else {
                    outcome.failed.append((url, "couldn’t be written"))
                }
            }
            DispatchQueue.main.async { finished(outcome) }
        }
    }
}

/// The sheet that asks how a batch should be named and where it should go.
final class BulkExportSheet: NSObject {
    private let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 250),
                                 styleMask: [.titled], backing: .buffered, defer: false)
    private let suffixField = NSTextField(string: Preferences.exportSuffix)
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let destLabel = ThemedLabel("Beside each original", role: .secondary, size: 11)
    private let example = ThemedLabel("", role: .tertiary, size: 10)
    private let progress = NSProgressIndicator()
    private let status = ThemedLabel("", role: .secondary, size: 11)
    private var goButton: NSButton!

    private var destination: URL?
    private let count: Int
    private let sample: URL?
    private var onRun: ((BulkExport.Options) -> Void)?

    init(count: Int, sample: URL?) {
        self.count = count
        self.sample = sample
        super.init()
    }

    /// Ask, then hand back what was chosen. Nil if cancelled.
    func present(over host: NSWindow, run: @escaping (BulkExport.Options) -> Void) {
        onRun = run
        panel.title = "Export \(count) edited image\(count == 1 ? "" : "s")"

        suffixField.placeholderString = "graded"
        suffixField.target = self
        suffixField.action = #selector(refreshExample)
        suffixField.delegate = self

        for f in ExportFormatAccessory.Format.allCases {
            formatPopup.addItem(withTitle: f.label)
            formatPopup.lastItem?.tag = f.rawValue
        }
        formatPopup.selectItem(withTag: ExportFormatAccessory.Format
            .from(extension: Preferences.lastExportExtension).rawValue)
        formatPopup.target = self
        formatPopup.action = #selector(refreshExample)

        let chooseButton = NSButton(title: "Choose…", target: self,
                                    action: #selector(chooseDestination))
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small
        let besideButton = NSButton(title: "Beside originals", target: self,
                                    action: #selector(clearDestination))
        besideButton.bezelStyle = .rounded
        besideButton.controlSize = .small

        goButton = NSButton(title: "Export", target: self, action: #selector(go))
        goButton.bezelStyle = .rounded
        goButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = Double(count)
        progress.isHidden = true

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

        let dest = NSStackView(views: [destLabel, besideButton, chooseButton])
        dest.orientation = .horizontal
        dest.spacing = 8
        let buttons = NSStackView(views: [NSView(), cancel, goButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let column = NSStackView(views: [
            row("Suffix", suffixField), row("Format", formatPopup),
            row("Location", dest), row("", example), progress, status, buttons,
        ])
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
            suffixField.widthAnchor.constraint(equalToConstant: 180),
            progress.widthAnchor.constraint(equalToConstant: 400),
            buttons.widthAnchor.constraint(equalToConstant: 400),
        ])
        panel.contentView = content
        refreshExample()
        host.beginSheet(panel)
    }

    private var chosenFormat: ExportFormatAccessory.Format {
        ExportFormatAccessory.Format(rawValue: formatPopup.selectedTag()) ?? .png
    }

    /// Showing the actual filename is the whole explanation of what a suffix is.
    @objc private func refreshExample() {
        guard let sample else { example.stringValue = ""; return }
        let opts = BulkExport.Options(suffix: suffixField.stringValue,
                                      format: chosenFormat, destination: destination)
        example.stringValue = "e.g.  " + BulkExport.destination(for: sample, options: opts)
            .lastPathComponent
        example.applyTheme()
    }

    @objc private func chooseDestination() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.message = "Where should the exported images go?"
        guard p.runModal() == .OK, let url = p.url else { return }
        destination = url
        destLabel.stringValue = url.lastPathComponent
        destLabel.applyTheme()
        refreshExample()
    }

    @objc private func clearDestination() {
        destination = nil
        destLabel.stringValue = "Beside each original"
        destLabel.applyTheme()
        refreshExample()
    }

    @objc private func go() {
        Preferences.exportSuffix = suffixField.stringValue
        Preferences.lastExportExtension = chosenFormat.ext
        goButton.isEnabled = false
        suffixField.isEnabled = false
        formatPopup.isEnabled = false
        progress.isHidden = false
        onRun?(BulkExport.Options(suffix: suffixField.stringValue,
                                  format: chosenFormat, destination: destination))
    }

    func report(done: Int, of total: Int) {
        progress.doubleValue = Double(done)
        status.stringValue = "Exporting \(done + 1) of \(total)…"
        status.applyTheme()
    }

    @objc func close() {
        panel.sheetParent?.endSheet(panel)
    }
}

extension BulkExportSheet: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { refreshExample() }
}
