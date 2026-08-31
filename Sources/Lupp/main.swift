import AppKit

// No @main / no storyboard: the app is assembled in code so it builds with the
// Command Line Tools alone, and so nothing loads at launch that a viewer of a
// single image doesn't need.
if CommandLine.arguments.contains("--selftest") {
    print("Lupp selftest")
    exit(Selftest.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
