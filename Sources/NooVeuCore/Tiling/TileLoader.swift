import CoreGraphics
import Foundation

/// Loads the tiles a view currently wants, from a `TileSource`.
///
/// The view calls `want(_:alreadyHeld:)` whenever what is on screen changes, with the tiles it needs,
/// nearest the centre first, and the tiles it already holds (on the GPU). The loader decodes the rest a
/// few at a time, in that order, and delivers each through `tiles`. It keeps a byte-limited cache of
/// decoded tiles, so a tile the GPU dropped and the view wants again is delivered without decoding.
///
/// - A queued tile that is no longer wanted is dropped, so fast panning never builds a backlog (a decode
///   already running finishes, and its result is cached).
/// - A tile asked for again while it is running or queued is not decoded twice.
/// - A tile that finishes after the view moved on is cached but not delivered.
/// - A tile that failed is not retried until `invalidate()`: a view that asks every frame would
///   otherwise retry a broken tile forever.
///
/// `tiles` is a single-consumer stream: a second consumer would take tiles from the first.
public actor TileLoader {
    public struct Statistics: Sendable, Equatable {
        public var decodesStarted = 0
        public var cacheHits = 0
        public var droppedQueued = 0
        public var failures = 0
    }

    public enum TileState: Sendable, Equatable {
        case cached, running, queued, failed
        /// Never requested, or forgotten.
        case unknown
    }

    /// Tiles ready for the view, in the order they finish. The view uploads each to the GPU.
    public nonisolated let tiles: AsyncStream<TileBitmap>
    public private(set) var statistics = Statistics()
    public nonisolated let maxConcurrentDecodes: Int

    private let source: any TileSource
    private var cache: LRUCache<TileID, TileBitmap>
    private let delivery: AsyncStream<TileBitmap>.Continuation
    private var wanted: [TileID] = []
    private var queue: [TileID] = []
    /// Tiles being decoded, and the generation each was started in.
    private var running: [TileID: Int] = [:]
    private var failed: Set<TileID> = []
    /// Tiles delivered that the view has not yet reported holding. While a delivered tile is still
    /// being uploaded, a request that does not list it as held must not deliver it a second time.
    private var awaitingUpload: Set<TileID> = []
    /// Bumped by `invalidate()`: results of decodes started before it are discarded.
    private var generation = 0
    private var isClosed = false

    /// - Parameters:
    ///   - cacheBytes: Memory for decoded tiles that are kept for later (not the GPU's copies).
    ///   - maxConcurrentDecodes: Tiles decoded at once.
    public init(source: any TileSource, cacheBytes: Int = 128 << 20, maxConcurrentDecodes: Int = 3) {
        self.source = source
        self.cache = LRUCache(costLimit: cacheBytes)
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes)
        (tiles, delivery) = AsyncStream<TileBitmap>.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        // A loader dropped without `close()` must not leave its consumer waiting forever.
        delivery.finish()
    }

    public var cachedCount: Int { cache.count }
    public var queuedCount: Int { queue.count }
    public var runningCount: Int { running.count }

    /// What the loader knows about a tile.
    public func state(of id: TileID) -> TileState {
        if cache.contains(id) { return .cached }
        if running[id] == generation { return .running }
        if queue.contains(id) { return .queued }
        if failed.contains(id) { return .failed }
        return .unknown
    }

    /// The tiles that failed to decode and will not be retried until `invalidate()`.
    public var failedTiles: Set<TileID> { failed }

    /// Sets the tiles wanted now, most important first. Those already decoded are delivered at once;
    /// the rest are queued in this order, replacing whatever was queued before.
    ///
    /// - Parameter alreadyHeld: Tiles the view already has (uploaded to the GPU). They are neither
    ///   delivered again nor decoded, which keeps a view that calls this every frame from re-uploading
    ///   what it holds. A tile the view drops should be left out of this set the next time. A tile
    ///   delivered but not yet listed here (its upload is under way) is not delivered again by a later
    ///   request either, as long as it stays wanted; once it has been listed, leaving it out again
    ///   (the GPU evicted it) asks for it afresh.
    public func want(_ ids: [TileID], alreadyHeld: Set<TileID> = []) {
        guard !isClosed else { return }
        wanted = ids
        let wantedSet = Set(ids)
        awaitingUpload.formIntersection(wantedSet)
        awaitingUpload.subtract(alreadyHeld)

        statistics.droppedQueued += queue.filter { !wantedSet.contains($0) }.count
        queue.removeAll()

        var seen = Set<TileID>()
        for id in ids where seen.insert(id).inserted {
            guard source.grid.isValid(id), !alreadyHeld.contains(id) else { continue }
            if awaitingUpload.contains(id) {
                continue
            } else if let cached = cache.value(for: id) {
                statistics.cacheHits += 1
                awaitingUpload.insert(id)
                delivery.yield(cached)
            } else if running[id] != generation && !failed.contains(id) {
                queue.append(id)
            }
        }
        pump()
    }

    /// Forgets cached tiles and failures, for when the file behind the source changed, and loads the
    /// wanted tiles again. Decodes already running are discarded when they finish. The view must
    /// discard the tiles it holds, too.
    public func invalidate() {
        generation += 1
        cache.removeAll()
        failed.removeAll()
        awaitingUpload.removeAll()
        guard !isClosed else { return }
        want(wanted)
    }

    /// Stops loading and ends `tiles`. Decodes already running finish and are discarded.
    public func close() {
        isClosed = true
        queue.removeAll()
        wanted.removeAll()
        cache.removeAll()
        failed.removeAll()
        awaitingUpload.removeAll()
        delivery.finish()
    }

    private func pump() {
        while running.count < maxConcurrentDecodes, !queue.isEmpty {
            let id = queue.removeFirst()
            let startedIn = generation
            running[id] = startedIn
            statistics.decodesStarted += 1
            let source = self.source
            Task {
                // (`Result` has an async initialiser only in newer toolchains.)
                let result: Result<TileBitmap, Error>
                do { result = .success(try await source.tile(id)) } catch { result = .failure(error) }
                self.finish(id, startedIn, result)
            }
        }
    }

    private func finish(_ id: TileID, _ startedIn: Int, _ result: Result<TileBitmap, Error>) {
        if running[id] == startedIn { running[id] = nil }
        defer { pump() }
        // Closed, or the file changed since this decode began: its pixels are no use.
        guard !isClosed, startedIn == generation else { return }
        switch result {
        case .success(let tile):
            cache.insert(tile, for: id, cost: tile.byteCost)
            if wanted.contains(id) {
                awaitingUpload.insert(id)
                delivery.yield(tile)
            }
        case .failure:
            statistics.failures += 1
            // Bounded by the number of tiles in the grid (only valid tiles are ever decoded).
            failed.insert(id)
        }
    }
}
