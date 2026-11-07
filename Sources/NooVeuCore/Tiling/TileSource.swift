import CoreGraphics
import Foundation

/// One tile's pixels: its padded area (see `TileGrid`) as a fully decoded 8-bit bitmap in a layout
/// Metal uploads directly.
public struct TileBitmap: @unchecked Sendable {
    public let id: TileID
    public let image: CGImage
    /// Where the bitmap sits in its level's pixels (the tile's content plus the border).
    public let paddedRect: PixelRect

    public init(id: TileID, image: CGImage, paddedRect: PixelRect) {
        self.id = id
        self.image = image
        self.paddedRect = paddedRect
    }

    public var byteCost: Int { image.bytesPerRow * image.height }
}

public enum TileError: Error, Equatable, Sendable {
    /// The tile is not part of the grid.
    case invalidTile(TileID)
    case renderFailed(TileID)
}

/// Where tile pixels come from.
///
/// Whole images are decoded for the screen elsewhere (`DecodeScheduler`); a tile source serves a
/// large image in pieces, so it never has to be uploaded or held as one texture.
public protocol TileSource: Sendable {
    /// The pyramid. Its level 0 is the pixels this source holds, which for an image too large to hold
    /// at full detail is smaller than the image (`detailFactor`).
    var grid: TileGrid { get }
    /// The image's true size in pixels (oriented), which is `grid`'s level 0 times `detailFactor`.
    var trueSize: PixelSize { get }
    /// Source pixels per pixel of `grid`'s level 0: 1 at full detail, 2 at half, and so on.
    var detailFactor: Double { get }
    /// Memory the source itself keeps while it exists (a decoded buffer; about nothing for a source
    /// that decodes from the file on demand).
    var retainedBytes: Int { get }

    /// Renders one tile. Safe to call from several tasks at once.
    func tile(_ id: TileID) async throws -> TileBitmap
}

/// Runs blocking decode work off the Swift cooperative pool, so a burst of tile decodes cannot starve
/// the interface's own async work (the same reason `DecodeScheduler` has its own queue). At most
/// `limit` run at once, however many are requested: a caller that asks for hundreds of tiles directly
/// (the `TileLoader` never does) cannot grow the thread count with them.
enum TileDecodeQueue {
    static let limit = 6

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ch.navicentral.nooveu.tiles"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = limit
        return queue
    }()

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

/// The bitmap layout every tile uses: 8-bit BGRA, premultiplied, little-endian.
enum TileBitmapLayout {
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    static func makeContext(width: Int, height: Int, colorSpace: CGColorSpace?) -> CGContext? {
        let space = (colorSpace?.model == .rgb ? colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: bitmapInfo)
    }
}

extension TileSource {
    /// The tiles to load for what the view shows, nearest the centre first.
    ///
    /// Takes everything in the image's own pixels (`sourceArea`, `center`, and `zoom` in device pixels
    /// per source pixel) and does the conversion to this source's grid, which at reduced detail
    /// (`detailFactor` above 1) is coarser than the image. Callers should use this rather than the grid
    /// directly, so they never mix the two units.
    public func tilesToLoad(sourceArea: CGRect, zoom: Double, center: CGPoint) -> [TileID] {
        let factor = max(detailFactor, 1)
        let level = grid.level(forZoom: zoom * factor)
        let scaledArea = CGRect(x: sourceArea.minX / factor, y: sourceArea.minY / factor,
                                width: sourceArea.width / factor, height: sourceArea.height / factor)
        return grid.tilesNearestFirst(level: level, covering: scaledArea,
                                      center: CGPoint(x: center.x / factor, y: center.y / factor))
    }

    /// Where a tile's content lies in the image's own pixels (for placing it on screen).
    public func sourceArea(of tile: TileID) -> CGRect {
        let content = grid.contentRect(of: tile)
        let scale = Double(1 << tile.level) * max(detailFactor, 1)
        // The last tile's last pixel can cover fewer source pixels than the others: clip to the image.
        let x = Double(content.x) * scale, y = Double(content.y) * scale
        return CGRect(x: x, y: y,
                      width: min(Double(content.width) * scale, Double(trueSize.width) - x),
                      height: min(Double(content.height) * scale, Double(trueSize.height) - y))
    }
}

/// Where a level's last pixel covers fewer source pixels than the others (the image's size is not a
/// multiple of 2^level), drawing at the exact scale leaves that pixel partly transparent. Scaling its
/// channels back up would amplify the 8-bit rounding (by up to 2^level), and the two tiles that share
/// the pixel would disagree, so it is replaced by its inner neighbour instead: opaque (or as
/// transparent as the image is), and identical in every tile that holds it, at the cost of at most one
/// pixel's detail at the very edge of the image.
enum TileEdge {
    static func replicateInnerNeighbour(in context: CGContext, padded: PixelRect, grid: TileGrid, level: Int) {
        let scale = 1 << level
        guard scale > 1, let data = context.data else { return }
        let level0 = grid.levelSize(0), size = grid.levelSize(level)
        let partialColumn = padded.maxX == size.width && level0.width % scale != 0 && padded.width > 1
        let partialRow = padded.maxY == size.height && level0.height % scale != 0 && padded.height > 1

        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let rowBytes = context.bytesPerRow
        if partialColumn {
            let last = padded.width - 1
            for row in 0..<padded.height {
                let from = pixels + row * rowBytes + (last - 1) * 4
                for channel in 0..<4 { from[4 + channel] = from[channel] }
            }
        }
        if partialRow {
            let last = padded.height - 1
            // The row above, whole: for the corner this also takes the diagonal neighbour.
            (pixels + last * rowBytes).update(from: pixels + (last - 1) * rowBytes, count: padded.width * 4)
        }
    }
}

/// How far around a coarse tile the decoder reads, in source pixels, so the scaling filter sees the
/// neighbours' pixels and a tile's border matches the neighbour's edge. Level 0 needs none.
enum TileMargin {
    static func sourcePixels(level: Int) -> Int { level == 0 ? 0 : 4 * (1 << level) }
}
