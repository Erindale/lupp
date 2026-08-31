import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    private var controllers: [ViewerWindowController] = []
    private var openedAtLaunch = false

    /// Offered by "Make Lupp the Default…". Deliberately not all 62 readable
    /// types: macOS prompts once per type, so this is the set worth the clicks.
    private static let defaultableTypes: [String] = [
        "public.jpeg", "public.png", "public.tiff", "com.compuserve.gif",
        "com.microsoft.bmp", "public.heic", "public.heif", "org.webmproject.webp",
        "public.avif", "public.jpeg-xl", "com.ilm.openexr-image", "public.radiance",
        "com.adobe.photoshop-image", "com.adobe.raw-image",
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)

        // Paths on argv, so `Lupp.app/Contents/MacOS/Lupp shot.exr` works from a
        // shell without going through LaunchServices.
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for p in paths {
            let url = URL(fileURLWithPath: p)
            if FileManager.default.fileExists(atPath: url.path) {
                openedAtLaunch = true
                present(url)
            }
        }

        // Finder hands us the file just after launch; only fall back to an open
        // panel if nothing arrived.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.openedAtLaunch, self.controllers.isEmpty else { return }
            self.openDocument(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        for url in urls { present(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The window a new one should avoid landing exactly on top of — they all
    /// share a single autosaved frame, so without this they'd stack invisibly.
    var frontmostViewerFrame: NSRect? { controllers.last?.window?.frame }

    func present(_ url: URL) {
        let c = ViewerWindowController(url: url)
        controllers.append(c)
        c.showWindow(nil)
    }

    func forget(_ c: ViewerWindowController) {
        controllers.removeAll { $0 === c }
    }

    // MARK: - Actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ImageLoader.readableTypes.compactMap { UTType($0) }
        panel.message = "Open an image"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { present(url) }
    }

    @objc func makeDefaultViewer(_ sender: Any?) {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            alert("Lupp has to be running from Lupp.app",
                  "Launch Session isn’t a bundle, so macOS has nothing to register. Run ./build.sh and open the built app.")
            return
        }
        guard #available(macOS 15.0, *) else {
            alert("Needs macOS 15 or later",
                  "Setting the default handler from inside an app requires macOS 15. On earlier versions: select an image in Finder, press ⌘I, and change “Open with” to Lupp, then click “Change All…”.")
            return
        }

        let types = AppDelegate.defaultableTypes.compactMap { UTType($0) }
        let a = NSAlert()
        a.messageText = "Make Lupp the default for \(types.count) image types?"
        a.informativeText = "macOS asks for confirmation once per file type, so expect \(types.count) prompts in a row. You can stop at any point — whatever you’ve confirmed so far sticks."
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            var failed: [String] = []
            for t in types {
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpen: t)
                } catch {
                    failed.append(t.preferredFilenameExtension ?? t.identifier)
                }
            }
            if !failed.isEmpty {
                alert("Some types weren’t changed",
                      "Skipped or declined: \(failed.joined(separator: ", ")).")
            }
        }
    }

    @objc func toggleScrollWheelZooms(_ sender: Any?) {
        Preferences.scrollWheelZooms.toggle()
    }

    @objc func toggleInvertScrollZoom(_ sender: Any?) {
        Preferences.invertScrollZoom.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleScrollWheelZooms(_:)) {
            item.state = Preferences.scrollWheelZooms ? .on : .off
        }
        if item.action == #selector(toggleInvertScrollZoom(_:)) {
            item.state = Preferences.invertScrollZoom ? .on : .off
        }
        return true
    }

    @objc func showReadableTypes(_ sender: Any?) {
        let list = ImageLoader.readableTypes.joined(separator: "\n")
        alert("\(ImageLoader.readableTypes.count) formats readable on this Mac",
              "These come from ImageIO, so the list tracks your macOS version.\n\n\(list)")
    }

    private func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Lupp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Make Lupp the Default Image Viewer…", action: #selector(makeDefaultViewer(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Formats Lupp Can Read…", action: #selector(showReadableTypes(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Lupp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Lupp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        let exportItem = fileMenu.addItem(withTitle: "Export as Displayed…",
                                          action: #selector(ViewerWindowController.exportImage(_:)),
                                          keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(ViewerWindowController.zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(ViewerWindowController.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size (1 image pixel : 1 screen pixel)", action: #selector(ViewerWindowController.zoomActualSize(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Zoom to Fit", action: #selector(ViewerWindowController.zoomFit(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        let next = viewMenu.addItem(withTitle: "Next Image", action: #selector(ViewerWindowController.nextImage(_:)), keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        next.keyEquivalentModifierMask = [.command]
        let prev = viewMenu.addItem(withTitle: "Previous Image", action: #selector(ViewerWindowController.previousImage(_:)), keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        prev.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Increase Exposure", action: #selector(ViewerWindowController.increaseExposure(_:)), keyEquivalent: "e")
        let decEV = viewMenu.addItem(withTitle: "Decrease Exposure", action: #selector(ViewerWindowController.decreaseExposure(_:)), keyEquivalent: "E")
        decEV.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(withTitle: "Reset Exposure", action: #selector(ViewerWindowController.resetExposure(_:)), keyEquivalent: "r")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Clipping Overlay", action: #selector(ViewerWindowController.toggleClipping(_:)), keyEquivalent: "c")
        viewMenu.addItem(withTitle: "False Colour", action: #selector(ViewerWindowController.toggleFalseColour(_:)), keyEquivalent: "f")
        viewMenu.addItem(.separator())
        let scopesItem = viewMenu.addItem(withTitle: "Scopes",
                                          action: #selector(ViewerWindowController.toggleScopes(_:)),
                                          keyEquivalent: "i")
        scopesItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(.separator())
        let scrollToggle = viewMenu.addItem(withTitle: "Scroll Wheel Zooms",
                                            action: #selector(toggleScrollWheelZooms(_:)), keyEquivalent: "")
        scrollToggle.target = self
        let invertToggle = viewMenu.addItem(withTitle: "Invert Scroll Zoom Direction",
                                            action: #selector(toggleInvertScrollZoom(_:)),
                                            keyEquivalent: "")
        invertToggle.target = self
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
