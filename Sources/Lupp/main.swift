import AppKit

// No @main / no storyboard: the app is assembled in code so it builds with the
// Command Line Tools alone, and so nothing loads at launch that a viewer of a
// single image doesn't need.
if CommandLine.arguments.contains("--selftest") {
    print("Lupp selftest")
    exit(Selftest.run())
}

// Diagnostic: `Lupp --parse-lut path.cube` reports what the parser makes of a
// file, so a LUT that won't load can be explained rather than guessed at.
if let i = CommandLine.arguments.firstIndex(of: "--parse-lut"),
   i + 1 < CommandLine.arguments.count {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let started = ProcessInfo.processInfo.systemUptime
    do {
        let lut = try CubeLUT.parse(url: url)
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        print("ok: \"\(lut.title)\"  size=\(lut.size)  entries=\(lut.rgba.count / 4)")
        print("    domain \(lut.domainMin) → \(lut.domainMax)")
        print(String(format: "    parsed in %.0f ms", ms))
    } catch {
        print("FAILED: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
