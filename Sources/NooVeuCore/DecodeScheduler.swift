import Foundation

public enum DecodePriority: Int, Sendable, Comparable {
    /// Background work for images the user may flip to next.
    case preload = 0
    /// The image the user is waiting to see.
    case visible = 1

    public static func < (lhs: DecodePriority, rhs: DecodePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The one path every surface uses to get pixels: a priority queue of decodes in front of
/// a memory-limited cache.
///
/// - Visible requests jump the queue; preloads wait behind them, nearest first.
/// - Two requests for the same image share one decode, including a visible request that
///   arrives while a preload of the same image is already running.
/// - A request whose task is cancelled leaves the queue. A decode that has already started
///   runs to completion (ImageIO cannot be interrupted) and its result is cached.
/// - `preload(_:)` drops queued preloads the user has moved away from, so fast flipping
///   never builds a backlog.
/// - Cache entries are keyed by the file's modification time and size as well as its path,
///   so a file saved over is decoded again.
/// - A file that failed to decode is not retried by `preload(_:)`, only by an explicit request.
/// - Decodes block their thread, so they run on a dispatch queue (not the Swift cooperative
///   pool), at most `maxConcurrentDecodes` at a time.
///
/// Not yet budgeted: memory held by decodes in flight. Phase 1's tiled rendering removes the
/// need to decode huge images whole.
public actor DecodeScheduler {
    public typealias Decoder = @Sendable (URL, DecodeOptions) throws -> DecodedImage

    /// Identifies a file's contents for caching: its path, when it was last written, and its size.
    struct FileStamp: Hashable, Sendable {
        var seconds = 0
        var nanoseconds = 0
        var size: Int64 = 0

        /// A file that cannot be inspected gets the all-zero stamp.
        init(_ url: URL) {
            var info = stat()
            let found = url.withUnsafeFileSystemRepresentation { path in
                path.map { stat($0, &info) == 0 } ?? false
            }
            if found {
                seconds = Int(info.st_mtimespec.tv_sec)
                nanoseconds = Int(info.st_mtimespec.tv_nsec)
                size = Int64(info.st_size)
            }
        }
    }

    public struct Key: Hashable, Sendable {
        public let url: URL
        public let options: DecodeOptions
        let stamp: FileStamp

        public init(url: URL, options: DecodeOptions) {
            self.url = url
            self.options = options
            self.stamp = FileStamp(url)
        }
    }

    public struct Statistics: Sendable, Equatable {
        public var decodesStarted = 0
        public var cacheHits = 0
        public var joinedInFlight = 0
        public var droppedPreloads = 0
        public var cancelledRequests = 0
    }

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<DecodedImage, Error>
    }

    /// Decodes run here. Blocking a cooperative-pool thread per decode would starve the
    /// interface's own async work on Macs with few cores.
    private static let decodeQueue = DispatchQueue(
        label: "ch.navicentral.nooveu.decode", qos: .userInitiated, attributes: .concurrent
    )
    private static let failureMemory = 256

    public nonisolated let maxConcurrentDecodes: Int
    public private(set) var statistics = Statistics()

    private let decoder: Decoder
    private var cache: LRUCache<Key, DecodedImage>
    private var pending: [(key: Key, priority: DecodePriority)] = []
    private var running: Set<Key> = []
    private var waiters: [Key: [Waiter]] = [:]
    private var nextWaiterID: UInt64 = 0
    private var failed: Set<Key> = []
    /// Keys queued as preloads that a visible request later promoted.
    private var promoted: Set<Key> = []

    public init(
        costLimit: Int = DecodeScheduler.defaultCostLimit(),
        maxConcurrentDecodes: Int = DecodeScheduler.defaultConcurrency(),
        decoder: @escaping Decoder = { url, options in try ImageDecoder.decode(url, options: options) }
    ) {
        self.cache = LRUCache(costLimit: costLimit)
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes)
        self.decoder = decoder
    }

    /// An eighth of installed memory, between 256 MB and 2 GB: about ten 24-megapixel
    /// images on an 8 GB Mac and twenty on a 16 GB one.
    public static func defaultCostLimit(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let eighth = Int(clamping: physicalMemory / 8)
        return min(max(eighth, 256 << 20), 2 << 30)
    }

    /// Half the cores, between 2 and 4.
    public static func defaultConcurrency(cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        max(2, min(4, cores / 2))
    }

    public var cachedCost: Int { cache.totalCost }
    public var cachedCount: Int { cache.count }
    /// Decodes waiting for a free slot.
    public var queuedCount: Int { pending.count }
    /// Files remembered as undecodable.
    public var failedCount: Int { failed.count }

    /// The image if it is already decoded, without starting any work.
    public func cachedImage(for url: URL, options: DecodeOptions = .fullResolution) -> DecodedImage? {
        cache.value(for: Key(url: url, options: options))
    }

    /// Returns the decoded image, from the cache when possible, otherwise by queueing a decode
    /// (or joining one already queued or running).
    /// - Throws: `CancellationError` if the calling task is cancelled while waiting, or the
    ///   decoder's error.
    public func image(
        for url: URL,
        options: DecodeOptions = .fullResolution,
        priority: DecodePriority = .visible
    ) async throws -> DecodedImage {
        let key = Key(url: url, options: options)
        if let hit = cache.value(for: key) {
            statistics.cacheHits += 1
            return hit
        }
        try Task.checkCancellation()

        let id = nextWaiterID
        nextWaiterID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // This body runs on the actor before any suspension, so the waiter is
                // registered before a concurrent cancellation can look for it.
                if running.contains(key) || pending.contains(where: { $0.key == key }) {
                    statistics.joinedInFlight += 1
                }
                failed.remove(key)  // an explicit request always retries
                waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
                enqueue(key, priority: priority)
                pump()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id, key: key) }
        }
    }

    /// Queues background decodes for `urls`, nearest first, and drops queued preloads that
    /// are not in `urls`. Images already cached, running, failed before, or wanted by a
    /// visible request are skipped.
    public func preload(_ urls: [URL], options: DecodeOptions = .fullResolution) {
        let keys = urls.map { Key(url: $0, options: options) }
        let wanted = Set(keys)

        // Queued preloads nobody asked for and nobody is waiting on are dropped. An entry with a
        // waiter stays, whatever its priority: someone called `image(for:)` and expects it.
        let dropped = pending.filter { $0.priority == .preload && !wanted.contains($0.key) && waiters[$0.key] == nil }
        statistics.droppedPreloads += dropped.count

        // Rebuild the queue: what must stay first, then the wanted preloads in the caller's
        // order, so the nearest image is first even if farther ones were queued earlier.
        let kept = pending.filter { $0.priority == .visible || waiters[$0.key] != nil }
        let keptKeys = Set(kept.map(\.key))
        var queued = Set<Key>()
        var preloads: [(key: Key, priority: DecodePriority)] = []
        for key in keys where queued.insert(key).inserted {
            if running.contains(key) || keptKeys.contains(key) || failed.contains(key) { continue }
            // Touching a cached neighbour keeps it from being evicted.
            if cache.value(for: key) != nil { continue }
            preloads.append((key, .preload))
        }
        pending = kept + preloads
        pump()
    }

    /// Empties the cache and the failure memory, for example under memory pressure.
    /// Queued and running decodes continue.
    public func purge() {
        cache.removeAll()
        failed.removeAll()
    }

    // MARK: Queue

    private func enqueue(_ key: Key, priority: DecodePriority) {
        if running.contains(key) { return }
        if let index = pending.firstIndex(where: { $0.key == key }) {
            guard priority > pending[index].priority else { return }
            pending.remove(at: index)
            promoted.insert(key)
        }
        if priority == .visible {
            pending.insert((key, priority), at: 0)
        } else {
            pending.append((key, priority))
        }
    }

    private func pump() {
        while running.count < maxConcurrentDecodes, !pending.isEmpty {
            let key = pending.removeFirst().key
            promoted.remove(key)
            running.insert(key)
            statistics.decodesStarted += 1

            let decoder = self.decoder
            Self.decodeQueue.async {
                let result = Result { try decoder(key.url, key.options) }
                Task { await self.finish(key, result) }
            }
        }
    }

    private func finish(_ key: Key, _ result: Result<DecodedImage, Error>) {
        running.remove(key)
        switch result {
        case .success(let image):
            cache.insert(image, for: key, cost: image.byteCost)
        case .failure:
            if failed.count >= Self.failureMemory { failed.removeAll() }
            failed.insert(key)
        }
        for waiter in waiters.removeValue(forKey: key) ?? [] {
            waiter.continuation.resume(with: result)
        }
        pump()
    }

    private func cancelWaiter(id: UInt64, key: Key) {
        guard var list = waiters[key], let index = list.firstIndex(where: { $0.id == id }) else { return }
        let waiter = list.remove(at: index)
        waiters[key] = list.isEmpty ? nil : list
        statistics.cancelledRequests += 1
        waiter.continuation.resume(throwing: CancellationError())

        // Nobody is waiting for a queued visible decode any more. Drop it, unless it began as a
        // preload: then it goes back to being one, and the next `preload(_:)` keeps or drops it.
        // (A running decode finishes either way.)
        if waiters[key] == nil, let queued = pending.firstIndex(where: { $0.key == key && $0.priority == .visible }) {
            pending.remove(at: queued)
            if promoted.remove(key) != nil {
                pending.append((key, .preload))
            }
        }
    }
}
