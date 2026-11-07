import CoreGraphics
import Foundation
import Metal
import NooVeuCore

/// Shows a large image from tiles: works out which tiles the view needs, has them decoded
/// (`TileLoader`), uploads them off the main thread, keeps them within the GPU budget
/// (`TileTextureCache`) and hands the renderer what to draw.
///
/// Call `update(for:)` whenever the view changes (zoom, pan, resize) and draw what it returns after the
/// base texture. While a wanted tile is still on its way, the nearest resident tile of a coarser level
/// that covers it is drawn in its place (coarsest first, so finer ones draw over them); the caller's
/// base texture sits under all of it. (Resident tiles finer than the wanted level are not used as
/// stand-ins.) `onTilesChanged` fires on the main actor each time a tile has been uploaded: redraw and call
/// `update(for:)` again.
@MainActor
public final class TileLayer {
    public let source: any TileSource
    public let cache: TileTextureCache
    public let loader: TileLoader
    public var onTilesChanged: (() -> Void)?

    private var consumer: Task<Void, Never>?
    private var pending: [TileID]?
    private var lastWanted: [TileID] = []
    private var lastChangeCount = -1
    private var isSending = false
    private var isClosed = false

    /// - Parameters:
    ///   - gpuBudgetBytes: Memory for tiles on the GPU.
    ///   - decodeCacheBytes: Memory for decoded tiles kept to be re-uploaded without decoding.
    public init(source: any TileSource, device: MTLDevice, gpuBudgetBytes: Int = 256 << 20,
                decodeCacheBytes: Int = 128 << 20, maxConcurrentDecodes: Int = 3) {
        self.source = source
        self.cache = TileTextureCache(device: device, budgetBytes: gpuBudgetBytes)
        self.loader = TileLoader(source: source, cacheBytes: decodeCacheBytes, maxConcurrentDecodes: maxConcurrentDecodes)
        let stream = loader.tiles
        let cache = self.cache
        consumer = Task.detached(priority: .userInitiated) { [weak self] in
            for await bitmap in stream {
                // Upload here, off the main thread; only the notification comes back to it. A tile
                // already on the GPU can arrive again (a request sent just before it was uploaded did
                // not know of it): nothing to do.
                guard cache.tile(bitmap.id) == nil else { continue }
                // (A bitmap that cannot be uploaded is skipped; the sources only make uploadable ones.)
                guard let texture = cache.makeTexture(for: bitmap) else { continue }
                cache.insert(bitmap.id, texture: texture, paddedRect: bitmap.paddedRect)
                await self?.tileArrived()
            }
        }
    }

    isolated deinit {
        // Dropped without `close()`: stop the loader too, or it keeps decoding for nobody.
        consumer?.cancel()
        cache.close()
        let loader = self.loader
        Task { await loader.close() }
    }

    private func tileArrived() {
        guard !isClosed else { return }
        onTilesChanged?()
    }

    /// The tiles the view needs now at the zoom's level, nearest the centre first.
    public func wantedTiles(for transform: ViewTransform) -> [TileID] {
        guard transform.viewSize.width > 0, transform.viewSize.height > 0, transform.zoom > 0 else { return [] }
        return source.tilesToLoad(sourceArea: transform.visibleSourceRect, zoom: Double(transform.zoom),
                                  center: transform.center)
    }

    /// Plans the view: asks for the tiles it needs and returns what to draw now, in drawing order.
    public func update(for transform: ViewTransform) -> [TileQuad] {
        guard !isClosed else { return [] }
        let wanted = wantedTiles(for: transform)
        var drawn: [TileID: ResidentTile] = [:]
        var used: [TileID] = []
        for id in wanted {
            if let tile = cache.tile(id) {
                drawn[id] = tile
            } else {
                // Stand in with the nearest resident coarser tile that covers it.
                var ancestor = source.grid.parent(of: id)
                while let candidate = ancestor {
                    if let tile = cache.tile(candidate) { drawn[candidate] = tile; break }
                    ancestor = source.grid.parent(of: candidate)
                }
            }
        }
        used = Array(drawn.keys)
        cache.markUsed(used)
        // Ask again only when the view's tiles or what the GPU holds changed since last time.
        if wanted != lastWanted || cache.changeCount != lastChangeCount {
            lastWanted = wanted
            lastChangeCount = cache.changeCount
            send(ids: wanted)
        }

        // Coarse first: finer tiles draw over the stand-ins.
        return drawn.sorted { ($0.key.level, $0.key.row, $0.key.column) > ($1.key.level, $1.key.row, $1.key.column) }
            .compactMap { TileQuad.make($0.key, tile: $0.value, source: source, transform: transform) }
    }

    /// Stops loading and releases the GPU's tiles. The layer draws nothing afterwards.
    public func close() {
        isClosed = true
        consumer?.cancel()
        consumer = nil
        onTilesChanged = nil
        cache.close()
        let loader = self.loader
        Task { await loader.close() }
    }

    /// Hands the loader the latest request. Requests are sent one at a time, newest wins, so a slow
    /// one can never land after a newer one.
    private func send(ids: [TileID]) {
        pending = ids
        guard !isSending else { return }
        isSending = true
        let loader = self.loader
        Task { [weak self] in
            // What the GPU holds is read when the request is sent, not when it was made.
            while let request = self?.takePending() {
                await loader.want(request.ids, alreadyHeld: request.held)
            }
            self?.isSending = false
        }
    }

    private func takePending() -> (ids: [TileID], held: Set<TileID>)? {
        defer { pending = nil }
        return pending.map { ($0, cache.residentIDs) }
    }
}
