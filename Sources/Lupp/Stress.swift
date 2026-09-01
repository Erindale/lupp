import AppKit
import Foundation

/// `Lupp --stress <folder> [count]` — what a long editing session costs.
///
/// Two things now accumulate for as long as a window is open: the per-image edit
/// cache, and one undo history per image. Both are unbounded by design — you
/// cannot know in advance how many frames someone will grade — so the question
/// is not whether they grow but whether they grow at a rate that matters.
/// Guessing is how you either ship a leak or spend a day fixing a kilobyte.
enum Stress {
    /// Physical footprint, the number Activity Monitor shows.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1e6
    }

    static func ms(_ body: () -> Void) -> Double {
        let t = ProcessInfo.processInfo.systemUptime
        body()
        return (ProcessInfo.processInfo.systemUptime - t) * 1000
    }

    static func run(folder: URL, count wanted: Int, undoDepth: Int = 200) -> Int32 {
        let urls = ((try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: nil)) ?? [])
            .filter { ImageLoader.canRead($0) }
            .sorted { $0.path < $1.path }
        guard !urls.isEmpty else {
            print("no readable images at \(folder.path)")
            return 1
        }
        let n = min(wanted, urls.count)
        print("Lupp stress — \(n) images from \(folder.lastPathComponent), \(undoDepth) undo steps each\n")

        let base = footprintMB()
        print(String(format: "baseline footprint            %8.1f MB", base))

        // What a window accumulates: one Session per edited image, one undo
        // history per image. Built through the real types, not stand-ins.
        var edits: [URL: Session] = [:]
        var undoStacks: [URL: UndoManager] = [:]
        var sessionTotal = 0.0
        var worstSession = 0.0

        for (i, url) in urls.prefix(n).enumerated() {
            // A grade that differs per image, so nothing can be shared by luck.
            var d = Renderer.DisplayState()
            d.exposureEV = Float(i % 7) * 0.25 - 0.75
            d.contrast = 1 + Float(i % 5) * 0.05
            d.saturation = 1 - Float(i % 4) * 0.1
            d.whiteBalance = SIMD3(1 + Float(i % 3) * 0.02, 1, 1)
            d.cropEnabled = i % 3 == 0
            d.crop = SIMD4(0.05, 0.05, 0.9, 0.9)

            let t = ms { edits[url] = Session.from(d, image: url, lutPath: nil,
                                                   bookmark: false) }
            sessionTotal += t
            worstSession = max(worstSession, t)

            // Depth is a parameter because the worst case (the 200-step cap on
            // every image) and a realistic one say very different things.
            let undo = UndoManager()
            undo.levelsOfUndo = 200
            for step in 0..<undoDepth {
                var p = Preset.from(d, lutPath: nil)
                p.name = ""
                p.exposureEV = Float(step) * 0.01
                undo.registerUndo(withTarget: undo) { _ in _ = p }
            }
            undoStacks[url] = undo
        }

        let after = footprintMB()
        print(String(format: "after %3d edited images       %8.1f MB   (+%.1f MB, %.0f KB each)",
                     n, after, after - base, (after - base) * 1000 / Double(n)))
        print("")
        print(String(format: "Session.from  mean %6.2f ms   worst %6.2f ms   total %6.0f ms",
                     sessionTotal / Double(n), worstSession, sessionTotal))
        print("  — paid once per navigation away from an edited image")

        // What the in-memory cache no longer pays. A saved .lupp still carries a
        // bookmark, so that an image which moved can be found again; the cached
        // copy skips it, and this is the cost of the decision — a filesystem
        // round trip per navigation, which over SMB is a network one.
        var bookmarkTotal = 0.0, worstBookmark = 0.0
        for url in urls.prefix(n) {
            let t = ms {
                _ = try? url.bookmarkData(options: .minimalBookmark,
                                          includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            bookmarkTotal += t
            worstBookmark = max(worstBookmark, t)
        }
        print(String(format: "bookmark, skipped here  mean %6.2f ms   worst %6.2f ms   total %6.0f ms",
                     bookmarkTotal / Double(n), worstBookmark, bookmarkTotal))
        print("  — what a saved session pays, and what navigation no longer does")

        // A dictionary lookup is the only thing navigation adds; if that were
        // ever the problem, something else has gone very wrong.
        var found = 0
        let lookup = ms {
            for _ in 0..<10_000 {
                for url in urls.prefix(n) where edits[url] != nil { found += 1 }
            }
        }
        print(String(format: "\ncache lookup  %.3f µs per hit over %d hits",
                     lookup * 1000 / Double(found), found))

        // Held so nothing above is optimised away before it is measured.
        print("\nheld: \(edits.count) sessions, \(undoStacks.count) histories")
        return 0
    }
}
