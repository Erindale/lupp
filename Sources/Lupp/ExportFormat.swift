import AppKit
import UniformTypeIdentifiers

/// The format popup for the save panel.
///
/// `NSSavePanel` shows no format picker of its own — that is an NSDocument
/// feature — so without this the only way to choose one is to type the extension,
/// which is not a discoverable thing to expect of anybody.
final class ExportFormatAccessory: NSView {
    enum Format: Int, CaseIterable {
        case png, jpeg, tiff

        var label: String {
            switch self {
            case .png:  return "PNG · 8-bit"
            case .jpeg: return "JPEG · 8-bit, quality 95"
            case .tiff: return "TIFF · 16-bit"
            }
        }
        var ext: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .tiff: return "tif"
            }
        }
        var type: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .tiff: return .tiff
            }
        }
        /// 16 bits only where the depth is the reason to pick the format.
        var bitDepth: Int { self == .tiff ? 16 : 8 }

        static func from(extension e: String) -> Format {
            switch e.lowercased() {
            case "jpg", "jpeg": return .jpeg
            case "tif", "tiff": return .tiff
            default: return .png
            }
        }
    }

    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var panel: NSSavePanel?

    var format: Format { Format(rawValue: popup.indexOfSelectedItem) ?? .png }

    init(panel: NSSavePanel, initial: Format) {
        self.panel = panel
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 40))

        let label = NSTextField(labelWithString: "Format:")
        label.font = .systemFont(ofSize: 12)
        popup.addItems(withTitles: Format.allCases.map(\.label))
        popup.selectItem(at: initial.rawValue)
        popup.target = self
        popup.action = #selector(changed)

        for v in [label, popup] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 40),
        ])
        apply()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func changed() { apply() }

    /// Keep the filename's extension and the panel's filter in step with the
    /// choice, so the name in the field always says what will be written.
    private func apply() {
        guard let panel else { return }
        panel.allowedContentTypes = [format.type]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        if !base.isEmpty {
            panel.nameFieldStringValue = base + "." + format.ext
        }
    }
}
