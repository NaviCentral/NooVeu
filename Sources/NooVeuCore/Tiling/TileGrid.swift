import CoreGraphics
import Foundation

/// Names one tile of an image pyramid: level 0 is full resolution, each higher level is half the
/// size of the one below, and each level is cut into a grid of square tiles.
public struct TileID: Hashable, Sendable, CustomStringConvertible {
    public let level: Int
    public let column: Int
    public let row: Int

    public init(level: Int, column: Int, row: Int) {
        self.level = level
        self.column = column
        self.row = row
    }

    public var description: String { "L\(level)(\(column),\(row))" }
}

/// A rectangle of whole pixels.
public struct PixelRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// The geometry of an image pyramid cut into tiles.
///
/// Pure arithmetic with no pixels: which levels exist, which tiles cover an area, how a tile's area
/// relates to its level, and which level suits a zoom. Level 0 is `sourceSize`, which is the size of
/// the pixels we actually hold: for an image too large to hold at full detail it is a reduced size
/// (see `TileSourceFactory`).
///
/// Each tile is stored with a `border` of extra pixels on every side that touch a neighbour (its
/// "padded" area), so that smooth sampling at a tile's edge sees the neighbour's pixels and no seam
/// shows between tiles.
public struct TileGrid: Hashable, Sendable {
    public let sourceSize: PixelSize
    public let tileSize: Int
    public let border: Int
    /// Fewer levels than the image has, when the source cannot serve the coarse ones cheaply.
    public let maxLevels: Int?

    /// - Parameter maxLevels: Cap on the number of levels (at least 1). A coarse level of a large image
    ///   covers most of it, which some sources cannot decode cheaply; the screen-sized first view serves
    ///   those zooms instead, and `level(forZoom:)` never asks for a level beyond the cap.
    public init(sourceSize: PixelSize, tileSize: Int = 512, border: Int = 1, maxLevels: Int? = nil) {
        precondition(sourceSize.width > 0 && sourceSize.height > 0, "an image has pixels")
        precondition(tileSize > 0 && border >= 0, "tiles have a size")
        self.sourceSize = sourceSize
        self.tileSize = tileSize
        self.border = border
        self.maxLevels = maxLevels.map { max($0, 1) }
    }

    // MARK: Levels

    /// How many levels there are: down to the first one that fits in a single tile (or `maxLevels`).
    public var levelCount: Int {
        var count = 1
        var size = sourceSize
        while size.longestSide > tileSize {
            size = PixelSize(width: (size.width + 1) / 2, height: (size.height + 1) / 2)
            count += 1
        }
        return min(count, maxLevels ?? Int.max)
    }

    public func levelSize(_ level: Int) -> PixelSize {
        var width = sourceSize.width, height = sourceSize.height
        for _ in 0..<max(level, 0) {
            width = (width + 1) / 2
            height = (height + 1) / 2
        }
        return PixelSize(width: max(width, 1), height: max(height, 1))
    }

    public func columns(level: Int) -> Int { (levelSize(level).width + tileSize - 1) / tileSize }
    public func rows(level: Int) -> Int { (levelSize(level).height + tileSize - 1) / tileSize }

    public func isValid(_ id: TileID) -> Bool {
        id.level >= 0 && id.level < levelCount
            && id.column >= 0 && id.column < columns(level: id.level)
            && id.row >= 0 && id.row < rows(level: id.level)
    }

    /// The level whose resolution is the lowest that is still at least as sharp as the screen needs:
    /// the coarsest level with at least `zoom` pixels per source pixel. `zoom` is device pixels per
    /// source pixel (1 shows source pixels one to one).
    public func level(forZoom zoom: Double) -> Int {
        guard zoom > 0 else { return levelCount - 1 }  // zero, negative or not a number
        guard zoom < 1 else { return 0 }  // one to one or magnified, however far
        let level = Int((-log2(zoom)).rounded(.down))
        return min(max(level, 0), levelCount - 1)
    }

    // MARK: Tile areas

    /// The tile's own area in its level's pixels, without the border.
    public func contentRect(of id: TileID) -> PixelRect {
        let size = levelSize(id.level)
        let x = id.column * tileSize, y = id.row * tileSize
        return PixelRect(x: x, y: y, width: min(tileSize, size.width - x), height: min(tileSize, size.height - y))
    }

    /// The tile's area including the border, clipped to the level (no border is added where there is
    /// no neighbour). This is what a tile's bitmap holds.
    public func paddedRect(of id: TileID) -> PixelRect {
        let size = levelSize(id.level)
        let content = contentRect(of: id)
        let x0 = max(content.x - border, 0), y0 = max(content.y - border, 0)
        let x1 = min(content.maxX + border, size.width), y1 = min(content.maxY + border, size.height)
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The tile that contains this one one level up (coarser), if there is one.
    public func parent(of id: TileID) -> TileID? {
        guard id.level + 1 < levelCount else { return nil }
        return TileID(level: id.level + 1, column: id.column / 2, row: id.row / 2)
    }

    // MARK: Covering an area

    /// The tiles of `level` that cover `area`, given in source (level 0) pixels, in reading order.
    /// An area partly or wholly outside the image is clipped to it; one wholly outside gives none.
    public func tiles(level: Int, covering area: CGRect) -> [TileID] {
        guard level >= 0, level < levelCount, area.width > 0, area.height > 0,
              area.minX.isFinite, area.minY.isFinite, area.maxX.isFinite, area.maxY.isFinite else { return [] }
        let size = levelSize(level)
        let scale = Double(1 << level)
        // Clamp before converting: an area of 1e19 pixels is finite but does not fit an Int.
        func pixel(_ value: Double, upTo limit: Int) -> Int { Int(min(max(value, 0), Double(limit))) }
        let x0 = pixel((area.minX / scale).rounded(.down), upTo: size.width)
        let y0 = pixel((area.minY / scale).rounded(.down), upTo: size.height)
        // The far edge belongs to the area exclusively: an area ending exactly on a tile boundary
        // does not touch the next tile.
        let x1 = pixel((area.maxX / scale).rounded(.up), upTo: size.width) - 1
        let y1 = pixel((area.maxY / scale).rounded(.up), upTo: size.height) - 1
        guard x0 <= x1, y0 <= y1 else { return [] }
        var result: [TileID] = []
        for row in (y0 / tileSize)...(y1 / tileSize) {
            for column in (x0 / tileSize)...(x1 / tileSize) {
                result.append(TileID(level: level, column: column, row: row))
            }
        }
        return result
    }

    /// The same tiles, nearest to `center` (source pixels) first: the order to load them in.
    public func tilesNearestFirst(level: Int, covering area: CGRect, center: CGPoint) -> [TileID] {
        let scale = Double(1 << max(level, 0))
        func distance(_ id: TileID) -> Double {
            let rect = contentRect(of: id)
            let cx = (Double(rect.x) + Double(rect.width) / 2) * scale
            let cy = (Double(rect.y) + Double(rect.height) / 2) * scale
            return (cx - center.x) * (cx - center.x) + (cy - center.y) * (cy - center.y)
        }
        // Reading order breaks ties, so the result is the same every time.
        return tiles(level: level, covering: area).enumerated()
            .sorted { (distance($0.element), $0.offset) < (distance($1.element), $1.offset) }
            .map(\.element)
    }
}
