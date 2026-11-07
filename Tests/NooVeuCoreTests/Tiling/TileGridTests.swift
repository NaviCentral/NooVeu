import CoreGraphics
import Testing
@testable import NooVeuCore

@Suite("TileGrid")
struct TileGridTests {
    /// 1000×700 in 256 px tiles: levels of 1000×700, 500×350 and 250×175.
    private let grid = TileGrid(sourceSize: PixelSize(width: 1000, height: 700), tileSize: 256, border: 1)

    // MARK: Levels

    @Test func levelsHalveUntilTheyFitOneTile() {
        #expect(grid.levelCount == 3)
        #expect(grid.levelSize(0) == PixelSize(width: 1000, height: 700))
        #expect(grid.levelSize(1) == PixelSize(width: 500, height: 350))
        #expect(grid.levelSize(2) == PixelSize(width: 250, height: 175))
    }

    @Test func oddSizesRoundUpSoNoPixelIsLost() {
        let odd = TileGrid(sourceSize: PixelSize(width: 5, height: 3), tileSize: 1)
        #expect(odd.levelSize(1) == PixelSize(width: 3, height: 2))
        #expect(odd.levelSize(2) == PixelSize(width: 2, height: 1))
        #expect(odd.levelSize(3) == PixelSize(width: 1, height: 1))
    }

    @Test func aSinglePixelImageIsOneTileOfOnePixel() {
        let one = TileGrid(sourceSize: PixelSize(width: 1, height: 1))
        #expect(one.levelCount == 1)
        #expect(one.contentRect(of: TileID(level: 0, column: 0, row: 0)) == PixelRect(x: 0, y: 0, width: 1, height: 1))
        #expect(one.paddedRect(of: TileID(level: 0, column: 0, row: 0)) == PixelRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func tileCountsRoundUp() {
        #expect(grid.columns(level: 0) == 4 && grid.rows(level: 0) == 3)
        #expect(grid.columns(level: 1) == 2 && grid.rows(level: 1) == 2)
        #expect(grid.columns(level: 2) == 1 && grid.rows(level: 2) == 1)
    }

    @Test func anExtremeImageHasEightLevelsAndNoOverflow() {
        let huge = TileGrid(sourceSize: PixelSize(width: 40_000, height: 20_000), tileSize: 512)

        #expect(huge.levelCount == 8)
        #expect(huge.columns(level: 0) == 79 && huge.rows(level: 0) == 40)
        #expect(huge.levelSize(7) == PixelSize(width: 313, height: 157))
        #expect(huge.isValid(TileID(level: 0, column: 78, row: 39)))
        #expect(!huge.isValid(TileID(level: 0, column: 79, row: 0)))
    }

    @Test func validIdsAreExactlyThoseInsideTheGrid() {
        #expect(grid.isValid(TileID(level: 0, column: 3, row: 2)))
        #expect(!grid.isValid(TileID(level: 0, column: 4, row: 0)))
        #expect(!grid.isValid(TileID(level: 0, column: 0, row: 3)))
        #expect(!grid.isValid(TileID(level: 3, column: 0, row: 0)))
        #expect(!grid.isValid(TileID(level: -1, column: 0, row: 0)))
        #expect(!grid.isValid(TileID(level: 0, column: -1, row: 0)))
    }

    // MARK: Choosing a level

    @Test func theLevelIsTheCoarsestOneStillAsSharpAsTheScreenNeeds() {
        #expect(grid.level(forZoom: 2) == 0, "magnified: source pixels")
        #expect(grid.level(forZoom: 1) == 0)
        #expect(grid.level(forZoom: 0.6) == 0, "a half-size level would be softer than needed")
        #expect(grid.level(forZoom: 0.5) == 1, "exactly half: the half-size level is just sharp enough")
        #expect(grid.level(forZoom: 0.3) == 1)
        #expect(grid.level(forZoom: 0.25) == 2)
    }

    @Test func theLevelNeverLeavesTheGrid() {
        #expect(grid.level(forZoom: 0.01) == 2, "clamped to the coarsest level")
        #expect(grid.level(forZoom: 0) == 2)
        #expect(grid.level(forZoom: -3) == 2)
        #expect(grid.level(forZoom: .nan) == 2)
        #expect(grid.level(forZoom: .infinity) == 0)
    }

    // MARK: Tile areas

    @Test func tilesCoverTheLevelExactlyOnceWithoutOverlap() {
        for tileSize in [1, 7, 64, 256, 1000, 5000] {
            let g = TileGrid(sourceSize: PixelSize(width: 1000, height: 700), tileSize: tileSize)
            for level in 0..<min(g.levelCount, 4) {
                let size = g.levelSize(level)
                var area = 0
                for row in 0..<g.rows(level: level) {
                    for column in 0..<g.columns(level: level) {
                        let rect = g.contentRect(of: TileID(level: level, column: column, row: row))
                        #expect(rect.x >= 0 && rect.y >= 0 && rect.maxX <= size.width && rect.maxY <= size.height)
                        #expect(rect.width > 0 && rect.height > 0)
                        area += rect.width * rect.height
                    }
                }
                #expect(area == size.width * size.height, "tile \(tileSize), level \(level)")
            }
        }
    }

    @Test func anEdgeTileIsSmallerThanTheRest() {
        let edge = grid.contentRect(of: TileID(level: 0, column: 3, row: 2))

        #expect(edge == PixelRect(x: 768, y: 512, width: 232, height: 188))
    }

    @Test func thePaddedAreaAddsABorderOnlyWhereThereIsANeighbour() {
        #expect(grid.paddedRect(of: TileID(level: 0, column: 0, row: 0)) == PixelRect(x: 0, y: 0, width: 257, height: 257),
                "no border beyond the image's top-left corner")
        #expect(grid.paddedRect(of: TileID(level: 0, column: 1, row: 1)) == PixelRect(x: 255, y: 255, width: 258, height: 258),
                "a border on every side")
        #expect(grid.paddedRect(of: TileID(level: 0, column: 3, row: 2)) == PixelRect(x: 767, y: 511, width: 233, height: 189),
                "clipped at the bottom-right edge")
    }

    @Test func aWiderBorderIsHonoured() {
        let wide = TileGrid(sourceSize: PixelSize(width: 1000, height: 700), tileSize: 256, border: 4)

        #expect(wide.paddedRect(of: TileID(level: 0, column: 1, row: 1)) == PixelRect(x: 252, y: 252, width: 264, height: 264))
    }

    @Test func aParentIsTheTileOneLevelUpThatContainsIt() {
        #expect(grid.parent(of: TileID(level: 0, column: 3, row: 2)) == TileID(level: 1, column: 1, row: 1))
        #expect(grid.parent(of: TileID(level: 0, column: 2, row: 1)) == TileID(level: 1, column: 1, row: 0))
        #expect(grid.parent(of: TileID(level: 1, column: 1, row: 1)) == TileID(level: 2, column: 0, row: 0))
        #expect(grid.parent(of: TileID(level: 2, column: 0, row: 0)) == nil, "the top has no parent")
    }

    // MARK: Covering an area

    @Test func anAreaEndingOnATileBoundaryDoesNotTouchTheNextTile() {
        #expect(grid.tiles(level: 0, covering: CGRect(x: 0, y: 0, width: 256, height: 256)) == [TileID(level: 0, column: 0, row: 0)])
        #expect(grid.tiles(level: 0, covering: CGRect(x: 0, y: 0, width: 257, height: 10)).map(\.column) == [0, 1])
    }

    @Test func anAreaOnACornerNeedsAllFourTilesInReadingOrder() {
        let tiles = grid.tiles(level: 0, covering: CGRect(x: 250, y: 250, width: 10, height: 10))

        #expect(tiles == [TileID(level: 0, column: 0, row: 0), TileID(level: 0, column: 1, row: 0),
                          TileID(level: 0, column: 0, row: 1), TileID(level: 0, column: 1, row: 1)])
    }

    @Test func anAreaIsClippedToTheImage() {
        #expect(grid.tiles(level: 0, covering: CGRect(x: -50, y: -50, width: 100, height: 100)) == [TileID(level: 0, column: 0, row: 0)])
        #expect(grid.tiles(level: 0, covering: CGRect(x: 900, y: 600, width: 5000, height: 5000)) == [TileID(level: 0, column: 3, row: 2)],
                "running far past the corner still means only the corner tile")
        #expect(grid.tiles(level: 0, covering: CGRect(x: 2000, y: 0, width: 10, height: 10)).isEmpty, "wholly outside")
        #expect(grid.tiles(level: 0, covering: CGRect(x: -100, y: 0, width: 50, height: 10)).isEmpty, "wholly left of it")
    }

    @Test func nonsenseAreasGiveNoTiles() {
        #expect(grid.tiles(level: 0, covering: CGRect(x: 0, y: 0, width: 0, height: 10)).isEmpty)
        #expect(grid.tiles(level: 0, covering: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)).isEmpty)
        #expect(grid.tiles(level: 0, covering: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)).isEmpty)
        #expect(grid.tiles(level: 5, covering: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty, "no such level")
        #expect(grid.tiles(level: -1, covering: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
    }

    @Test func aCoarserLevelCoversTheSameAreaWithFewerTiles() {
        let whole = CGRect(x: 0, y: 0, width: 1000, height: 700)

        #expect(grid.tiles(level: 0, covering: whole).count == 12)
        #expect(grid.tiles(level: 1, covering: whole).count == 4)
        #expect(grid.tiles(level: 2, covering: whole).count == 1)
        // Source pixels 500..510 are level-1 pixels 250..255: still the first column of 256.
        #expect(grid.tiles(level: 1, covering: CGRect(x: 500, y: 0, width: 10, height: 10)) == [TileID(level: 1, column: 0, row: 0)])
        #expect(grid.tiles(level: 1, covering: CGRect(x: 512, y: 0, width: 10, height: 10)) == [TileID(level: 1, column: 1, row: 0)])
    }

    // MARK: Loading order

    @Test func tilesAreLoadedNearestTheCentreFirst() {
        let whole = CGRect(x: 0, y: 0, width: 1000, height: 700)

        let order = grid.tilesNearestFirst(level: 0, covering: whole, center: CGPoint(x: 900, y: 650))

        #expect(order.first == TileID(level: 0, column: 3, row: 2))
        #expect(order.last == TileID(level: 0, column: 0, row: 0))
        #expect(Set(order).count == 12)
    }

    @Test func theLoadingOrderIsTheSameEveryTime() {
        let whole = CGRect(x: 0, y: 0, width: 1000, height: 700)
        // A centre exactly between tiles: ties must resolve the same way each call.
        let first = grid.tilesNearestFirst(level: 0, covering: whole, center: CGPoint(x: 512, y: 256))

        for _ in 0..<5 {
            #expect(grid.tilesNearestFirst(level: 0, covering: whole, center: CGPoint(x: 512, y: 256)) == first)
        }
    }

    // MARK: Awkward areas and sizes

    @Test func enormousAreasAreClippedNotTrapped() {
        for rect in [CGRect(x: 0, y: 0, width: 1e19, height: 100), CGRect(x: -1e19, y: 0, width: 2e19, height: 100),
                     CGRect(x: 1e30, y: 0, width: 10, height: 10), CGRect(x: 0, y: -1e300, width: 10, height: 2e300)] {
            let tiles = grid.tiles(level: 0, covering: rect)
            #expect(tiles.allSatisfy { grid.isValid($0) }, "\(rect)")
        }
        #expect(grid.tiles(level: 0, covering: CGRect(x: 0, y: 0, width: 1e19, height: 1e19)).count == 12, "the whole image")
        #expect(grid.tiles(level: 0, covering: CGRect(x: 1e30, y: 0, width: 10, height: 10)).isEmpty)
    }

    @Test func fractionalAreasTouchEveryTileTheyOverlap() {
        // The area 255.4 ..< 256.2 spans the boundary at 256.
        #expect(grid.tiles(level: 0, covering: CGRect(x: 255.4, y: 0, width: 0.8, height: 10)).map(\.column) == [0, 1])
        // Starting exactly on the boundary touches only the tile on its far side.
        #expect(grid.tiles(level: 0, covering: CGRect(x: 256, y: 0, width: 5, height: 10)).map(\.column) == [1])
        // Ending a fraction past a boundary reaches the next tile.
        #expect(grid.tiles(level: 0, covering: CGRect(x: 0, y: 0, width: 256.01, height: 10)).map(\.column) == [0, 1])
        #expect(grid.tiles(level: 0, covering: CGRect(x: 0, y: 255.5, width: 10, height: 1)).map(\.row) == [0, 1])
    }

    @Test func aCoarserLevelMapsFractionalSourceAreasToItsOwnPixels() {
        // Source x 511 ..< 513 is level-1 x 255.5 ..< 256.5: the boundary at 256 is crossed.
        #expect(grid.tiles(level: 1, covering: CGRect(x: 511, y: 0, width: 2, height: 10)).map(\.column) == [0, 1])
        // Level 2 is only 250 wide: source 1023 ..< 1025 is past its end.
        #expect(grid.tiles(level: 2, covering: CGRect(x: 1023, y: 0, width: 2, height: 10)).isEmpty)
    }

    @Test func theLevelCountRoundsHalvingUp() {
        // 513 -> 257 -> 129: three levels. Rounding down would give 513 -> 256 -> 128: two, and the
        // top level would be 257 px wide, no longer fitting one 256 px tile.
        let g = TileGrid(sourceSize: PixelSize(width: 513, height: 10), tileSize: 256)
        #expect(g.levelCount == 3)
        #expect(g.levelSize(g.levelCount - 1).longestSide <= 256)
    }

    @Test func theNearestFirstOrderAccountsForTheLevelScale() {
        // At level 1 a tile covers twice as much source. The centre is in source pixels.
        let whole = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let order = grid.tilesNearestFirst(level: 1, covering: whole, center: CGPoint(x: 990, y: 5))

        #expect(order.first == TileID(level: 1, column: 1, row: 0), "the top-right tile")
        #expect(order.last == TileID(level: 1, column: 0, row: 1), "the bottom-left tile")
    }

    @Test func aLevelCapLimitsTheLevelsAndTheLevelChosenForAZoom() {
        let capped = TileGrid(sourceSize: PixelSize(width: 1000, height: 700), tileSize: 256, maxLevels: 2)

        #expect(capped.levelCount == 2)
        #expect(capped.level(forZoom: 0.01) == 1, "never beyond the cap")
        #expect(!capped.isValid(TileID(level: 2, column: 0, row: 0)))
        #expect(capped.tiles(level: 2, covering: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(TileGrid(sourceSize: PixelSize(width: 1000, height: 700), tileSize: 256, maxLevels: 0).levelCount == 1, "at least one level")
        #expect(TileGrid(sourceSize: PixelSize(width: 100, height: 70), tileSize: 256, maxLevels: 9).levelCount == 1, "a cap above what exists changes nothing")
    }
}
