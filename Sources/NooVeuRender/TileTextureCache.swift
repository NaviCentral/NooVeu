import CoreGraphics
import Foundation
import Metal
import NooVeuCore
import Synchronization

/// A tile on the GPU: its texture (the tile's padded area, see `TileGrid`) and where that sits in
/// its level's pixels.
public struct ResidentTile: @unchecked Sendable {
    public let texture: MTLTexture
    public let paddedRect: PixelRect
    public let byteCount: Int
}

/// The GPU's copies of tiles, within a byte budget (256 MB by default).
///
/// Tiles the view is using are never evicted: `markUsed` names them (called whenever the view is
/// planned), and when the budget is exceeded the least recently used of the others go first. If the
/// tiles in use alone exceed the budget (a view needing more than the budget in tiles, which a screen
/// of tiles at the right level never does) the budget is exceeded rather than a visible tile dropped.
///
/// Thread safe: tiles are uploaded off the main thread and drawn on it.
public final class TileTextureCache: Sendable {
    public let device: MTLDevice
    public let budgetBytes: Int

    private struct Entry {
        var tile: ResidentTile
        var stamp: Int
        /// Orders tiles with the same stamp: when it was last inserted or marked used.
        var order: Int
    }

    private struct State {
        var entries: [TileID: Entry] = [:]
        var bytes = 0
        /// Counts `markUsed` calls. An entry with the current stamp is in use.
        var epoch = 0
        /// Counts insertions and markings, for `Entry.order`.
        var sequence = 0
        /// Counts changes to what is resident (insertions and evictions), so callers can tell cheaply
        /// whether the set of resident tiles has changed.
        var changes = 0
        var isClosed = false
    }

    private let state = Mutex(State())

    public init(device: MTLDevice, budgetBytes: Int = 256 << 20) {
        self.device = device
        self.budgetBytes = budgetBytes
    }

    /// Uploads a tile's pixels to a new texture. Safe to call from any thread; returns nil if the
    /// bitmap is not in the layout tile sources produce (8-bit BGRA).
    public func makeTexture(for bitmap: TileBitmap) -> MTLTexture? {
        let image = bitmap.image
        guard image.bitsPerPixel == 32, image.bitsPerComponent == 8,
              image.bitmapInfo.contains(.byteOrder32Little),
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= image.bytesPerRow * image.height else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: image.width, height: image.height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: image.bytesPerRow)
        return texture
    }

    /// Adds a tile (replacing one with the same id) and evicts the least recently used tiles that are
    /// not in use until the budget holds. The new tile counts as in use.
    public func insert(_ id: TileID, texture: MTLTexture, paddedRect: PixelRect) {
        let bytes = texture.width * texture.height * 4
        state.withLock { state in
            guard !state.isClosed else { return }
            if let old = state.entries[id] { state.bytes -= old.tile.byteCount }
            state.sequence += 1
            state.changes += 1
            state.entries[id] = Entry(tile: ResidentTile(texture: texture, paddedRect: paddedRect, byteCount: bytes),
                                      stamp: state.epoch, order: state.sequence)
            state.bytes += bytes
            while state.bytes > budgetBytes {
                guard let victim = state.entries.filter({ $0.value.stamp != state.epoch })
                    .min(by: { ($0.value.stamp, $0.value.order) < ($1.value.stamp, $1.value.order) })?.key else { break }
                state.bytes -= state.entries.removeValue(forKey: victim)!.tile.byteCount
                state.changes += 1
            }
        }
    }

    public func tile(_ id: TileID) -> ResidentTile? {
        state.withLock { $0.entries[id]?.tile }
    }

    /// Declares which tiles the view uses now; they are protected from eviction until the next call.
    public func markUsed(_ ids: some Sequence<TileID>) {
        state.withLock { state in
            state.epoch += 1
            for id in ids where state.entries[id] != nil {
                state.sequence += 1
                state.entries[id]?.stamp = state.epoch
                state.entries[id]?.order = state.sequence
            }
        }
    }

    public var residentIDs: Set<TileID> { state.withLock { Set($0.entries.keys) } }
    public var residentBytes: Int { state.withLock { $0.bytes } }
    public var count: Int { state.withLock { $0.entries.count } }

    /// Changes whenever a tile is added or evicted.
    public var changeCount: Int { state.withLock { $0.changes } }

    public func removeAll() {
        state.withLock { state in
            state.entries.removeAll()
            state.bytes = 0
            state.changes += 1
        }
    }

    /// Empties the cache for good: tiles inserted afterwards (an upload that was under way) are
    /// refused, so a closed view cannot refill it.
    public func close() {
        state.withLock { state in
            state.isClosed = true
            state.entries.removeAll()
            state.bytes = 0
            state.changes += 1
        }
    }
}
