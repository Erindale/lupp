import Foundation

/// Decoded images, kept for as long as the session and the memory budget allow.
///
/// Two things make scrolling a folder slow, and they need different answers.
/// Going *back* to something you have already seen should never cost anything,
/// so decoded images are cached. Going *forward* is predictable — you are
/// almost always about to want the next file — so neighbours are decoded before
/// you ask for them. Over a network share, where simply reading the bytes can
/// cost more than decoding them, the prefetch is worth more than the cache.
///
/// Nothing here writes to disk. A cache that outlived the session would be a
/// second copy of the user's photographs in a directory they never chose.
final class ImageStore {
    static let shared = ImageStore()

    /// Path, size and modification date together. Path alone would serve a stale
    /// picture after an edit — the same rule the LUT parser uses, for the same
    /// reason: a cache that can be wrong is worse than no cache.
    private struct Key: Hashable {
        let path: String
        let size: Int
        let modified: TimeInterval

        init?(_ url: URL) {
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            path = url.path
            size = (a[.size] as? Int) ?? 0
            modified = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        }
    }

    /// A share of physical memory, floored and capped.
    ///
    /// A sixteenth is deliberately modest. The prefetch only needs three frames
    /// to hide the network, and going back to compare is a handful more — past
    /// about ten there is nothing left to buy, and this is meant to be a viewer
    /// you leave open, not one that sits on a gigabyte for pictures you have
    /// finished looking at. On a 16GB machine it works out at ten 24MP frames,
    /// where the old float buffers would have fitted fewer than two.
    private static func budget() -> Int {
        let share = Int(ProcessInfo.processInfo.physicalMemory / 16)
        return min(max(share, 384 << 20), 1536 << 20)
    }

    private let lock = NSLock()
    private var entries: [Key: FloatImage] = [:]
    /// Least-recently-used first. Small enough that an array beats a list.
    private var order: [Key] = []
    private var bytes = 0
    private var inFlight: Set<Key> = []
    private let limit = ImageStore.budget()

    /// Prefetching must never make the image you actually asked for wait, so it
    /// runs below the foreground load and only two at a time — enough to stay
    /// ahead of a person pressing an arrow key, not enough to saturate an SMB
    /// mount with reads for pictures nobody has asked to see.
    private let prefetchQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()

    // MARK: - Reading

    /// What the cache is currently holding, for diagnostics.
    var heldBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    var heldCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// The decoded image, if it is already in memory.
    func cached(_ url: URL) -> FloatImage? {
        guard let key = Key(url) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let hit = entries[key] else { return nil }
        touch(key)
        return hit
    }

    /// Load `url`, from memory if possible.
    ///
    /// A cache hit calls back synchronously, on the caller's thread. That is the
    /// difference between going back to a picture and having it appear, and
    /// going back to a picture and watching a frame of blank window first.
    func load(_ url: URL, completion: @escaping (Result<FloatImage, Error>) -> Void) {
        if let hit = cached(url) { completion(.success(hit)); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try ImageLoader.load(url: url) }
            if case .success(let img) = result { self?.insert(img, for: url) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Decode these in the background if they are not already in memory.
    /// Order matters: the first is fetched first.
    func prefetch(_ urls: [URL]) {
        for url in urls {
            guard let key = Key(url) else { continue }
            lock.lock()
            let wanted = entries[key] == nil && !inFlight.contains(key)
            if wanted { inFlight.insert(key) }
            lock.unlock()
            guard wanted else { continue }

            prefetchQueue.addOperation { [weak self] in
                guard let self else { return }
                // Warming the statistics here too. They are measured over
                // hundreds of thousands of pixels, and doing that on arrival
                // would put it back on the main thread at exactly the moment
                // the window is trying to draw.
                let img = try? ImageLoader.load(url: url)
                if let img { _ = img.sourceStats }
                self.lock.lock()
                self.inFlight.remove(key)
                self.lock.unlock()
                if let img { self.insert(img, for: url) }
            }
        }
    }

    /// Drop everything. Used when the window closes, so a session's worth of
    /// photographs does not sit in memory for a window nobody is looking at.
    func empty() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
        bytes = 0
    }

    // MARK: - Bookkeeping

    private func insert(_ image: FloatImage, for url: URL) {
        guard let key = Key(url) else { return }
        lock.lock()
        defer { lock.unlock() }
        if entries[key] != nil { touch(key); return }
        // A single image larger than the whole budget would evict everything and
        // then not fit; better to hand it back uncached than to empty the cache
        // for something that cannot stay in it.
        guard image.bytesUsed <= limit else { return }
        entries[key] = image
        order.append(key)
        bytes += image.bytesUsed
        while bytes > limit, let oldest = order.first {
            order.removeFirst()
            if let evicted = entries.removeValue(forKey: oldest) { bytes -= evicted.bytesUsed }
        }
    }

    /// Move a key to the most-recently-used end. Called with the lock held.
    private func touch(_ key: Key) {
        guard let i = order.firstIndex(of: key) else { return }
        order.remove(at: i)
        order.append(key)
    }
}
