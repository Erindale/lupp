import Foundation

/// Sibling images in the same folder, for arrow-key navigation.
///
/// This is the feature that decides Lupp cannot be sandboxed: opening a file
/// under App Sandbox grants that file and nothing else, so the enclosing
/// directory would be unreadable and next/previous would silently do nothing.
enum FolderScanner {
    static func siblings(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [url] }

        let images = entries.filter(ImageLoader.canRead)
        guard !images.isEmpty else { return [url] }

        // Numeric collation, so frame_2 sorts before frame_10 rather than after it.
        return images.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent,
                                         options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
    }
}
