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

// Diagnostic: `Lupp --time-load <folder>` reports what each file costs to open,
// which storage it landed in, and what a second visit costs. Loading from a
// network share behaves nothing like loading from an SSD, and guessing which
// half of the time is the network is how you optimise the wrong one.
if let i = CommandLine.arguments.firstIndex(of: "--time-load"),
   i + 1 < CommandLine.arguments.count {
    let root = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    var urls = [root]
    if (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
        urls = ((try? FileManager.default.contentsOfDirectory(at: root,
                                                              includingPropertiesForKeys: nil)) ?? [])
            .filter { ImageLoader.canRead($0) }
            .sorted { $0.path < $1.path }
    }
    let sample = Array(urls.prefix(8))
    guard !sample.isEmpty else { print("no readable images at \(root.path)"); exit(1) }

    func time(_ b: () -> Void) -> Double {
        let t = ProcessInfo.processInfo.systemUptime
        b()
        return (ProcessInfo.processInfo.systemUptime - t) * 1000
    }

    var coldTotal = 0.0, warmTotal = 0.0
    for url in sample {
        var img: FloatImage?
        let cold = time { img = try? ImageLoader.load(url: url) }
        guard let img else { print("\(url.lastPathComponent): failed"); continue }
        let kind: String
        switch img.storage {
        case .srgbBytes:   kind = "sRGB bytes"
        case .linearFloat: kind = "linear float"
        }
        // Second visit through the store, which is what going back actually costs.
        ImageStore.shared.load(url) { _ in }
        let warm = time { _ = ImageStore.shared.cached(url) }
        coldTotal += cold; warmTotal += warm
        print(String(format: "%-18@ %5dx%-5d %-13@ %6.0f MB  decode %6.1f ms  revisit %5.2f ms",
                     url.lastPathComponent as NSString, img.width, img.height,
                     kind as NSString, Double(img.bytesUsed) / 1e6, cold, warm))
    }
    print(String(format: "\nmean over %d files: decode %.1f ms, revisit %.2f ms",
                 sample.count, coldTotal / Double(sample.count), warmTotal / Double(sample.count)))

    exit(0)
}

// Diagnostic: `Lupp --stress <folder> [count]` reports what a long editing
// session costs, since the edit cache and the undo histories are the two things
// that now grow for as long as a window stays open.
if let i = CommandLine.arguments.firstIndex(of: "--stress"),
   i + 1 < CommandLine.arguments.count {
    let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let count = i + 2 < CommandLine.arguments.count
        ? (Int(CommandLine.arguments[i + 2]) ?? 100) : 100
    let depth = i + 3 < CommandLine.arguments.count
        ? (Int(CommandLine.arguments[i + 3]) ?? 200) : 200
    exit(Stress.run(folder: folder, count: count, undoDepth: depth))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
