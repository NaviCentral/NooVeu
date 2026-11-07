import CoreGraphics
import Foundation
import ImageIO

/// Serves tiles by decoding just the needed region from the file, on demand.
///
/// Only some formats allow it cheaply. Measured on an M4 Pro, HEIC and AVIF decode a 512 px tile at
/// full resolution in about 10 ms whatever the image size, because they are stored as a grid of tiles;
/// JPEG and PNG have to decode everything first. A coarser level reads a larger area (a level-L tile
/// reads 2^L times as much), so it costs more: about 20 ms at level 1 and 40 ms at level 2 for a 100 MP
/// image, and far more beyond. This source therefore serves only the first levels (`maxServedLevels`),
/// which is all a tile layer over a screen-sized first view ever needs; the first view covers coarser
/// zooms. `TileSourceFactory` uses this source for the formats where it pays and checks the speed of
/// typical tiles before trusting it.
///
/// It keeps essentially no memory of its own (`retainedBytes` is 0). ImageIO decodes through a lazy
/// `CGImage` and holds a bounded cache; one lazy image decodes one region at a time, so the source holds
/// a small pool of independent ones, to decode several tiles at once. Measured on a 100 MP HEIC, the
/// process grows by about 50 MB in all while hundreds of tiles are decoded and dropped, and then stays
/// there.
final class RegionTileSource: TileSource, @unchecked Sendable {
    /// Levels served: 0 (full resolution), 1 and 2. See the class comment.
    static let maxServedLevels = 3
    /// Crops start on a multiple of this many pixels (HEVC's largest coding block is 64): cheap
    /// insurance, because a lossy codec's chroma interpolation can depend on where a crop starts.
    static let cropAlignment = 64

    let grid: TileGrid
    var trueSize: PixelSize { grid.sourceSize }
    let detailFactor: Double = 1
    private let pool: ImagePool
    private let orientation: CGImagePropertyOrientation
    private let storedSize: PixelSize

    /// - Parameter concurrency: Tiles that can be decoded at once (the size of the image pool).
    init(url: URL, tileSize: Int = 512, border: Int = 1, concurrency: Int = 3) throws {
        func makeImage() -> CGImage? {
            CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary).flatMap {
                CGImageSourceCreateImageAtIndex($0, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
            }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let info = SourceInfo(source),
              let first = makeImage()
        else { throw DecodeError.unreadable(url) }
        var images = [first]
        for _ in 1..<max(concurrency, 1) {
            guard let extra = makeImage() else { break }
            images.append(extra)
        }
        self.pool = ImagePool(images)
        self.orientation = info.orientation
        self.storedSize = PixelSize(width: first.width, height: first.height)
        self.grid = TileGrid(sourceSize: info.orientedSize, tileSize: tileSize, border: border, maxLevels: Self.maxServedLevels)
    }

    var retainedBytes: Int { 0 }

    func tile(_ id: TileID) async throws -> TileBitmap {
        try await TileDecodeQueue.run { try self.renderTile(id) }
    }

    func renderTile(_ id: TileID) throws -> TileBitmap {
        guard grid.isValid(id) else { throw TileError.invalidTile(id) }
        let stored = pool.acquire()
        defer { pool.release(stored) }

        let padded = grid.paddedRect(of: id)
        let scale = 1 << id.level
        let oriented = grid.levelSize(0)

        // The tile's area in oriented level-0 pixels, clipped to the image. Core Graphics' y axis
        // points up, so work in that space and convert at the edges.
        let ox0 = padded.x * scale, oy0 = padded.y * scale
        let ox1 = min(padded.maxX * scale, oriented.width), oy1 = min(padded.maxY * scale, oriented.height)
        let orientedUp = CGRect(x: ox0, y: oriented.height - oy1, width: ox1 - ox0, height: oy1 - oy0)
        // The bitmap's bottom edge, which lies beyond the image where the last pixel is partial.
        let bitmapBottom = Double(oriented.height - padded.maxY * scale)

        // Where that area, plus a margin at coarse levels (so the scaling filter has the neighbours'
        // pixels and no seam shows), lies in the stored (unrotated) image, which is all the file can
        // decode. The crop starts and ends on the codec's block grid.
        let margin = Double(TileMargin.sourcePixels(level: id.level))
        let wanted = orientedUp.insetBy(dx: -margin, dy: -margin)
            .intersection(CGRect(x: 0, y: 0, width: oriented.width, height: oriented.height))
        let transform = ImageDecoder.orientationTransform(orientation, width: CGFloat(storedSize.width), height: CGFloat(storedSize.height))
        let storedUp = wanted.applying(transform.inverted())
        let align = Self.cropAlignment
        let sx0 = max(Int(storedUp.minX.rounded(.down)) / align * align, 0)
        let sx1 = min((Int(storedUp.maxX.rounded(.up)) + align - 1) / align * align, storedSize.width)
        let sy1 = min(((storedSize.height - Int(storedUp.minY.rounded(.down))) + align - 1) / align * align, storedSize.height)
        let sy0 = max((storedSize.height - Int(storedUp.maxY.rounded(.up))) / align * align, 0)
        guard sx1 > sx0, sy1 > sy0,
              let region = stored.cropping(to: CGRect(x: sx0, y: sy0, width: sx1 - sx0, height: sy1 - sy0)),
              let context = TileBitmapLayout.makeContext(width: padded.width, height: padded.height, colorSpace: stored.colorSpace)
        else { throw TileError.renderFailed(id) }

        // Stored pixel -> displayed pixel -> this tile's pixel, applied in that order.
        // `.medium` so neighbouring tiles agree along their border (see BufferTileSource).
        context.interpolationQuality = id.level == 0 ? .none : .medium
        // Exactly 1/scale, so neighbouring tiles agree (see BufferTileSource); a partial last pixel is
        // replaced below.
        context.scaleBy(x: 1 / CGFloat(scale), y: 1 / CGFloat(scale))
        context.translateBy(x: -orientedUp.minX, y: -CGFloat(bitmapBottom))
        context.concatenate(transform)
        context.draw(region, in: CGRect(x: sx0, y: storedSize.height - sy1, width: sx1 - sx0, height: sy1 - sy0))
        TileEdge.replicateInnerNeighbour(in: context, padded: padded, grid: grid, level: id.level)
        guard let bitmap = context.makeImage() else { throw TileError.renderFailed(id) }
        return TileBitmap(id: id, image: bitmap, paddedRect: padded)
    }

    /// How long a typical tile takes to decode: the median of three tiles spread over the image, after
    /// one throwaway tile that pays the codec's one-off start-up cost (which alone can be about 80 ms
    /// and says nothing about the file). The factory uses it to tell a file that really decodes by
    /// region from one that decodes everything each time.
    func measureTypicalTile() throws -> Duration {
        let columns = grid.columns(level: 0), rows = grid.rows(level: 0)
        _ = try renderTile(TileID(level: 0, column: 0, row: 0))  // warm-up
        let clock = ContinuousClock()
        var times: [Duration] = []
        for (c, r) in [(columns / 2, rows / 2), (columns / 3, rows * 2 / 3), (columns * 2 / 3, rows / 3)] {
            let start = clock.now
            _ = try renderTile(TileID(level: 0, column: c, row: r))
            times.append(clock.now - start)
        }
        return times.sorted()[1]
    }
}

/// A few independent lazy images of one file, handed out one decode at a time.
final class ImagePool: @unchecked Sendable {
    private let condition = NSCondition()
    private var free: [CGImage]

    init(_ images: [CGImage]) { free = images }

    func acquire() -> CGImage {
        condition.lock()
        defer { condition.unlock() }
        while free.isEmpty { condition.wait() }
        return free.removeLast()
    }

    func release(_ image: CGImage) {
        condition.lock()
        free.append(image)
        condition.signal()
        condition.unlock()
    }
}
