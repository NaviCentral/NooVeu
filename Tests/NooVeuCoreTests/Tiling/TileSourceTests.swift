import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import NooVeuCore

/// Cuts every tile of a source's level 0 out of its bitmap and puts them together again.
func assembleLevelZero(_ source: some TileSource) async throws -> CGImage {
    let grid = source.grid
    let size = grid.levelSize(0)
    let canvas = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    canvas.interpolationQuality = .none
    for row in 0..<grid.rows(level: 0) {
        for column in 0..<grid.columns(level: 0) {
            let tile = try await source.tile(TileID(level: 0, column: column, row: row))
            let content = grid.contentRect(of: tile.id)
            // The content sits inside the padded bitmap, offset by the border.
            let inner = CGRect(x: content.x - tile.paddedRect.x, y: content.y - tile.paddedRect.y, width: content.width, height: content.height)
            let piece = tile.image.cropping(to: inner)!
            canvas.draw(piece, in: CGRect(x: content.x, y: size.height - content.y - content.height, width: content.width, height: content.height))
        }
    }
    return canvas.makeImage()!
}

@Suite("BufferTileSource")
struct BufferTileSourceTests {
    private let image = TestImages.gradient(width: 100, height: 70)

    private func source(tileSize: Int = 32, border: Int = 1, detail: Double = 1) -> BufferTileSource {
        BufferTileSource(image: image, detailFactor: detail, tileSize: tileSize, border: border)
    }

    @Test func theTilesPutBackTogetherAreTheImageExactly() async throws {
        let rebuilt = try await assembleLevelZero(source())

        #expect(TestImages.maxDifference(rebuilt, image) == 0)
    }

    @Test func itWorksForEveryTileSize() async throws {
        for tileSize in [1, 7, 31, 32, 64, 100, 512] {
            let rebuilt = try await assembleLevelZero(source(tileSize: tileSize))
            #expect(TestImages.maxDifference(rebuilt, image) == 0, "tile size \(tileSize)")
        }
    }

    @Test func aTileBitmapHoldsItsPaddedArea() async throws {
        let s = source()
        let tile = try await s.tile(TileID(level: 0, column: 1, row: 1))

        #expect(tile.paddedRect == PixelRect(x: 31, y: 31, width: 34, height: 34))
        #expect(tile.image.width == 34 && tile.image.height == 34)
    }

    @Test func theBorderHoldsTheNeighboursPixelsSoNoSeamShows() async throws {
        let s = source()
        let tile = try await s.tile(TileID(level: 0, column: 1, row: 1))

        // The bitmap is the image's own pixels 31..<65 in both directions, border included.
        let expected = image.cropping(to: CGRect(x: 31, y: 31, width: 34, height: 34))!
        #expect(TestImages.maxDifference(tile.image, expected) == 0)
    }

    @Test func noBorderIsInventedBeyondTheImageEdge() async throws {
        let s = source()
        let corner = try await s.tile(TileID(level: 0, column: 0, row: 0))
        let far = try await s.tile(TileID(level: 0, column: 3, row: 2))

        #expect(corner.paddedRect == PixelRect(x: 0, y: 0, width: 33, height: 33))
        #expect(far.paddedRect == PixelRect(x: 95, y: 63, width: 5, height: 7))
    }

    @Test func aCoarserLevelIsTheImageScaledDown() async throws {
        let s = source(tileSize: 64)
        let tile = try await s.tile(TileID(level: 1, column: 0, row: 0))
        // Level 1 is 50×35: one tile. Compare with the whole image scaled to that size.
        let context = CGContext(data: nil, width: 50, height: 35, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 50, height: 35))

        #expect(tile.paddedRect == PixelRect(x: 0, y: 0, width: 50, height: 35))
        #expect(TestImages.maxDifference(tile.image, context.makeImage()!) <= 2)
    }

    @Test func aTileOutsideTheGridIsRefused() async throws {
        let s = source()

        await #expect(throws: TileError.invalidTile(TileID(level: 0, column: 9, row: 0))) {
            _ = try await s.tile(TileID(level: 0, column: 9, row: 0))
        }
        await #expect(throws: TileError.self) { _ = try await s.tile(TileID(level: 7, column: 0, row: 0)) }
    }

    @Test func tilesAreReadyForTheGPUAndTheSourceReportsItsMemory() async throws {
        let s = source(detail: 2)
        let tile = try await s.tile(TileID(level: 0, column: 0, row: 0))

        #expect(tile.image.isMetalUploadable)
        #expect(tile.byteCost == tile.image.bytesPerRow * tile.image.height)
        #expect(s.retainedBytes >= 100 * 70 * 4)
        #expect(s.detailFactor == 2)
    }

    @Test func manyTilesCanBeRequestedAtOnce() async throws {
        let s = source()
        let grid = s.grid

        let results = try await withThrowingTaskGroup(of: TileBitmap.self) { group in
            for row in 0..<grid.rows(level: 0) {
                for column in 0..<grid.columns(level: 0) {
                    group.addTask { try await s.tile(TileID(level: 0, column: column, row: row)) }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results.count == 12)
        #expect(Set(results.map(\.id)).count == 12)
    }
}

@Suite("RegionTileSource")
struct RegionTileSourceTests {
    /// 100×70 stored; with orientations 5–8 it is displayed 70×100.
    private func write(_ type: String, ext: String, orientation: Int, in folder: TemporaryFolder) -> URL {
        // Smooth, like a photograph: razor-sharp colour edges every few pixels are not what lossy
        // codecs are for, and HEIC's chroma handling differs slightly at them depending on the crop.
        TestImages.writeGradient(width: 100, height: 70, smooth: true, to: folder.file("o\(orientation).\(ext)"), type: type,
                                 properties: [kCGImagePropertyOrientation: orientation])
    }

    @Test(arguments: ["public.jpeg", "public.heic"], 1...8)
    func theTilesPutBackTogetherAreTheFullDecodeForEveryOrientation(type: String, orientation: Int) async throws {
        let folder = try TemporaryFolder()
        let url = write(type, ext: type == "public.jpeg" ? "jpg" : "heic", orientation: orientation, in: folder)
        let source = try RegionTileSource(url: url, tileSize: 32)
        let expected = try ImageDecoder.decodeForTiling(url)

        let rebuilt = try await assembleLevelZero(source)

        #expect(source.grid.levelSize(0) == expected.sourcePixelSize, "oriented size")
        // Lossy formats decode the same pixels either way; allow a rounding of one or two levels.
        let difference = TestImages.maxDifference(rebuilt, expected.cgImage)
        #expect(difference <= 2, "\(type) orientation \(orientation): largest difference \(difference)")
    }

    @Test(arguments: [1, 6])
    func aLargerHeicWithAwkwardTileOffsetsStillMatchesTheFullDecode(orientation: Int) async throws {
        // 600×400 in 127 px tiles: crops start at 0, 126, 253, 380... none on a codec block boundary.
        let folder = try TemporaryFolder()
        let url = TestImages.writeGradient(width: 600, height: 400, smooth: true, to: folder.file("big.heic"), type: "public.heic",
                                           properties: [kCGImagePropertyOrientation: orientation])
        let source = try RegionTileSource(url: url, tileSize: 127)
        let expected = try ImageDecoder.decodeForTiling(url)

        let rebuilt = try await assembleLevelZero(source)

        let difference = TestImages.maxDifference(rebuilt, expected.cgImage)
        #expect(difference <= 2, "orientation \(orientation): largest difference \(difference)")
    }

    @Test func aCoarserLevelIsTheRegionScaledDown() async throws {
        let folder = try TemporaryFolder()
        let url = write("public.jpeg", ext: "jpg", orientation: 6, in: folder)
        let source = try RegionTileSource(url: url, tileSize: 64)
        let full = try ImageDecoder.decodeForTiling(url).cgImage
        let level1 = source.grid.levelSize(1)

        let tile = try await source.tile(TileID(level: 1, column: 0, row: 0))

        let context = CGContext(data: nil, width: level1.width, height: level1.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.interpolationQuality = .medium
        context.draw(full, in: CGRect(x: 0, y: 0, width: level1.width, height: level1.height))
        #expect(TestImages.maxDifference(tile.image, context.makeImage()!) <= 8, "a smooth scale, within resampling differences")
    }

    @Test func itKeepsNoMemoryOfItsOwnAndIsGPUReady() async throws {
        let folder = try TemporaryFolder()
        let source = try RegionTileSource(url: write("public.heic", ext: "heic", orientation: 1, in: folder), tileSize: 32)

        let tile = try await source.tile(TileID(level: 0, column: 1, row: 1))

        #expect(source.retainedBytes == 0)
        #expect(tile.image.isMetalUploadable)
        #expect(source.detailFactor == 1)
    }

    @Test func aTileOutsideTheGridIsRefused() async throws {
        let folder = try TemporaryFolder()
        let source = try RegionTileSource(url: write("public.jpeg", ext: "jpg", orientation: 1, in: folder), tileSize: 32)

        await #expect(throws: TileError.self) { _ = try await source.tile(TileID(level: 0, column: 50, row: 50)) }
    }

    @Test func aFileThatIsNotAnImageIsRefused() throws {
        let folder = try TemporaryFolder()
        try folder.touch("fake.heic", contents: "not an image")

        #expect(throws: DecodeError.self) { _ = try RegionTileSource(url: folder.file("fake.heic")) }
    }

    @Test func aTypicalTileCanBeTimed() throws {
        let folder = try TemporaryFolder()
        let source = try RegionTileSource(url: write("public.heic", ext: "heic", orientation: 1, in: folder), tileSize: 32)

        let time = try source.measureTypicalTile()

        #expect(time > .zero && time < .seconds(5))
    }

    @Test func onlyTheFirstLevelsAreServed() async throws {
        // A coarse level reads most of the image, which a region decode does not do cheaply.
        let folder = try TemporaryFolder()
        let url = TestImages.writeGradient(width: 600, height: 400, smooth: true, to: folder.file("big.jpg"), type: "public.jpeg")
        let source = try RegionTileSource(url: url, tileSize: 64)

        #expect(source.grid.levelCount == RegionTileSource.maxServedLevels)
        #expect(source.grid.level(forZoom: 0.001) == RegionTileSource.maxServedLevels - 1)
        await #expect(throws: TileError.invalidTile(TileID(level: 3, column: 0, row: 0))) {
            _ = try await source.tile(TileID(level: 3, column: 0, row: 0))
        }
    }

    @Test func manyTilesDecodedAtOnceAreTheSameAsOneAtATime() async throws {
        let folder = try TemporaryFolder()
        let url = TestImages.writeGradient(width: 400, height: 300, smooth: true, to: folder.file("a.heic"), type: "public.heic")
        let source = try RegionTileSource(url: url, tileSize: 64, concurrency: 3)
        let grid = source.grid
        var ids: [TileID] = []
        for row in 0..<grid.rows(level: 0) { for column in 0..<grid.columns(level: 0) { ids.append(TileID(level: 0, column: column, row: row)) } }
        var serial: [TileID: TileBitmap] = [:]
        for id in ids { serial[id] = try await source.tile(id) }

        let parallel = try await withThrowingTaskGroup(of: TileBitmap.self) { group in
            for id in ids + ids { group.addTask { try await source.tile(id) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(parallel.count == ids.count * 2)
        for tile in parallel {
            #expect(TestImages.maxDifference(tile.image, serial[tile.id]!.image) == 0, "\(tile.id)")
        }
    }
}

@Suite("Coarse levels")
struct CoarseLevelTests {
    /// The whole image scaled to a level's size: what a coarse level should look like.
    private func scaled(_ image: CGImage, to size: PixelSize) -> CGImage {
        let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()!
    }

    @Test(arguments: [1, 2])
    func aTileAwayFromTheOriginIsTheRightPartOfTheScaledImage(level: Int) async throws {
        // 320×200 divides evenly at levels 1 and 2, so every tile is a clean part of the scaled image.
        let image = TestImages.gradient(width: 320, height: 200, smooth: true)
        let source = BufferTileSource(image: image, tileSize: 32)
        let reference = scaled(image, to: source.grid.levelSize(level))
        let id = TileID(level: level, column: 2, row: 1)

        let tile = try await source.tile(id)

        let padded = tile.paddedRect
        let expected = reference.cropping(to: padded.cgRect)!
        #expect(padded.x > 0 && padded.y > 0, "an interior tile, not at the origin")
        #expect(TestImages.maxDifference(tile.image, expected) <= 3, "level \(level)")
    }

    @Test(arguments: [1, 2])
    func aTilesBorderEqualsItsNeighboursEdgeSoNoSeamShows(level: Int) async throws {
        // Noise is the worst case: any difference in how neighbouring tiles were scaled shows.
        let source = BufferTileSource(image: TestImages.noise(width: 320, height: 200), tileSize: 32)
        let left = try await source.tile(TileID(level: level, column: 1, row: 1))
        let right = try await source.tile(TileID(level: level, column: 2, row: 1))

        // The pixel at the last content column of `left` is also in `right`'s border.
        let leftPixels = TestImages.rgba(left.image), rightPixels = TestImages.rgba(right.image)
        let leftContent = source.grid.contentRect(of: left.id), rightContent = source.grid.contentRect(of: right.id)
        let x = leftContent.maxX - 1
        var worst = 0
        for y in leftContent.y..<min(leftContent.maxY, rightContent.maxY) {
            let l = ((y - left.paddedRect.y) * left.paddedRect.width + (x - left.paddedRect.x)) * 4
            let r = ((y - right.paddedRect.y) * right.paddedRect.width + (x - right.paddedRect.x)) * 4
            for c in 0..<3 { worst = max(worst, abs(Int(leftPixels[l + c]) - Int(rightPixels[r + c]))) }
        }
        #expect(worst <= 1, "level \(level): the same pixel from two tiles differs by \(worst)")
    }

    /// The largest difference, over a border shared by two tiles, between the same pixels in each.
    private func worstSharedBorder(_ source: some TileSource, level: Int, horizontal: Bool) async throws -> (worst: Int, pairs: Int) {
        let grid = source.grid
        var worst = 0, pairs = 0
        for row in 0..<grid.rows(level: level) {
            for column in 0..<grid.columns(level: level) {
                let a = TileID(level: level, column: column, row: row)
                let b = TileID(level: level, column: column + (horizontal ? 1 : 0), row: row + (horizontal ? 0 : 1))
                guard grid.isValid(b) else { continue }
                let ta = try await source.tile(a), tb = try await source.tile(b)
                let pa = TestImages.rgba(ta.image), pb = TestImages.rgba(tb.image)
                let content = grid.contentRect(of: a)
                // The last content line of `a` is also the first border line of `b`.
                let along = horizontal ? content.y..<content.maxY : content.x..<content.maxX
                for i in along {
                    let x = horizontal ? content.maxX - 1 : i, y = horizontal ? i : content.maxY - 1
                    let ia = ((y - ta.paddedRect.y) * ta.paddedRect.width + (x - ta.paddedRect.x)) * 4
                    let ib = ((y - tb.paddedRect.y) * tb.paddedRect.width + (x - tb.paddedRect.x)) * 4
                    for c in 0..<4 { worst = max(worst, abs(Int(pa[ia + c]) - Int(pb[ib + c]))) }
                }
                pairs += 1
            }
        }
        return (worst, pairs)
    }

    @Test(arguments: [1, 2, 3, 4])
    func everyBorderMatchesWhenTheSizeIsNotAMultipleOfTheScale(level: Int) async throws {
        // 1025×777 is odd, so at every level the last tile column and row end in a partial pixel.
        // Noise is the worst case. Both directions, every pair of neighbours, including the edge ones.
        let source = BufferTileSource(image: TestImages.noise(width: 1025, height: 777), tileSize: 32)

        let across = try await worstSharedBorder(source, level: level, horizontal: true)
        let down = try await worstSharedBorder(source, level: level, horizontal: false)

        #expect(across.pairs > 0 && down.pairs > 0)
        #expect(across.worst <= 2, "level \(level), side by side: \(across.worst)")
        #expect(down.worst <= 2, "level \(level), one above the other: \(down.worst)")
    }

    @Test(arguments: [1, 2, 3, 4])
    func theLastPixelOfAnOddSizedImageKeepsItsColour(level: Int) async throws {
        // A solid image: nothing, including the partial last pixel, may come out darker or see-through.
        let solid = TestImages.gradient(width: 1025, height: 777, smooth: true)
        let source = BufferTileSource(image: solid, tileSize: 32)
        let grid = source.grid
        let last = TileID(level: level, column: grid.columns(level: level) - 1, row: grid.rows(level: level) - 1)

        let tile = try await source.tile(last)

        let pixels = TestImages.rgba(tile.image)
        var minAlpha = 255
        for i in stride(from: 3, to: pixels.count, by: 4) { minAlpha = min(minAlpha, Int(pixels[i])) }
        #expect(minAlpha == 255, "level \(level): a pixel at the edge is partly transparent")
        // The corner pixel should be close to its inner neighbour (a smooth gradient changes slowly).
        let w = tile.paddedRect.width, h = tile.paddedRect.height
        let corner = ((h - 1) * w + (w - 1)) * 4, inner = ((h - 2) * w + (w - 2)) * 4
        for c in 0..<3 { #expect(abs(Int(pixels[corner + c]) - Int(pixels[inner + c])) <= 8, "level \(level) channel \(c)") }
    }

    @Test func anImageSmallerThanALevelPixelStillMakesTilesAtEveryLevel() async throws {
        for (w, h) in [(3, 2), (1, 1), (1, 5000 / 5), (7, 1)] {
            let source = BufferTileSource(image: TestImages.gradient(width: w, height: h, smooth: true), tileSize: 32)
            for level in 0..<source.grid.levelCount {
                for row in 0..<source.grid.rows(level: level) {
                    for column in 0..<source.grid.columns(level: level) {
                        let tile = try await source.tile(TileID(level: level, column: column, row: row))
                        #expect(tile.image.width == tile.paddedRect.width && tile.image.height == tile.paddedRect.height)
                    }
                }
            }
        }
    }

    @Test func theRegionSourceAgreesWithTheBufferSourceAtCoarseLevels() async throws {
        let folder = try TemporaryFolder()
        let url = TestImages.writeGradient(width: 320, height: 200, smooth: true, to: folder.file("a.jpg"), type: "public.jpeg",
                                           properties: [kCGImagePropertyOrientation: 6])
        let region = try RegionTileSource(url: url, tileSize: 32)
        let buffer = BufferTileSource(image: try ImageDecoder.decodeForTiling(url).cgImage, tileSize: 32)

        for level in 1...2 {
            let id = TileID(level: level, column: 1, row: 1)
            let a = try await region.tile(id), b = try await buffer.tile(id)
            #expect(TestImages.maxDifference(a.image, b.image) <= 6, "level \(level)")
        }
    }

    @Test(arguments: [1, 2])
    func theRegionSourceHandlesTheEdgeOfAnOddSizedImage(level: Int) async throws {
        let folder = try TemporaryFolder()
        let url = TestImages.writeGradient(width: 1025, height: 777, smooth: true, to: folder.file("odd.heic"), type: "public.heic")
        let region = try RegionTileSource(url: url, tileSize: 64)
        let buffer = BufferTileSource(image: try ImageDecoder.decodeForTiling(url).cgImage, tileSize: 64)
        let grid = region.grid
        let corner = TileID(level: level, column: grid.columns(level: level) - 1, row: grid.rows(level: level) - 1)
        let right = TileID(level: level, column: grid.columns(level: level) - 1, row: 1)
        let bottom = TileID(level: level, column: 1, row: grid.rows(level: level) - 1)

        for id in [corner, right, bottom] {
            let a = try await region.tile(id), b = try await buffer.tile(id)
            #expect(a.paddedRect == b.paddedRect)
            #expect(TestImages.maxDifference(a.image, b.image) <= 8, "level \(level) \(id)")
            let pixels = TestImages.rgba(a.image)
            var minAlpha = 255
            for i in stride(from: 3, to: pixels.count, by: 4) { minAlpha = min(minAlpha, Int(pixels[i])) }
            #expect(minAlpha == 255, "level \(level) \(id): no pixel may be partly transparent")
        }
    }

    @Test func aGreyImageStillMakesTilesTheGPUCanTake() async throws {
        let source = BufferTileSource(image: TestImages.grey(width: 100, height: 80), tileSize: 32)

        let tile = try await source.tile(TileID(level: 0, column: 1, row: 1))

        #expect(tile.image.isMetalUploadable, "a grey source still produces colour tiles")
    }
}

@Suite("TileSource helpers")
struct TileSourceHelperTests {
    @Test func aReducedSourceDoesTheUnitConversionForTheCaller() {
        // Held at half detail: its pixels are 2 source pixels each.
        let image = TestImages.gradient(width: 600, height: 400)
        let source = BufferTileSource(image: image, trueSize: PixelSize(width: 1200, height: 800), detailFactor: 2, tileSize: 128)

        // Source pixels 0..<300 are 150 grid pixels: two 128 px tiles.
        let tiles = source.tilesToLoad(sourceArea: CGRect(x: 0, y: 0, width: 300, height: 100), zoom: 0.5, center: CGPoint(x: 0, y: 0))

        #expect(source.trueSize == PixelSize(width: 1200, height: 800))
        #expect(tiles.first == TileID(level: 0, column: 0, row: 0))
        #expect(Set(tiles) == [TileID(level: 0, column: 0, row: 0), TileID(level: 0, column: 1, row: 0)])
    }

    @Test func theLevelFollowsTheZoomInGridPixels() {
        let image = TestImages.gradient(width: 600, height: 400)
        let half = BufferTileSource(image: image, trueSize: PixelSize(width: 1200, height: 800), detailFactor: 2, tileSize: 128)
        let full = BufferTileSource(image: image, tileSize: 128)
        let area = CGRect(x: 0, y: 0, width: 100, height: 100)

        // Zoom 0.5 on a half-detail source is zoom 1 on its own grid: level 0. On a full-detail one it is level 1.
        #expect(half.tilesToLoad(sourceArea: area, zoom: 0.5, center: .zero).first?.level == 0)
        #expect(full.tilesToLoad(sourceArea: area, zoom: 0.5, center: .zero).first?.level == 1)
    }

    @Test func theLastTilesAreaDoesNotReachBeyondTheImage() {
        // 1025 wide at level 1: 513 level pixels, the last covering one source pixel, not two.
        let source = BufferTileSource(image: TestImages.gradient(width: 1025, height: 777), tileSize: 32)
        let grid = source.grid
        let last = TileID(level: 1, column: grid.columns(level: 1) - 1, row: grid.rows(level: 1) - 1)

        let area = source.sourceArea(of: last)

        #expect(area.maxX == 1025 && area.maxY == 777, "\(area)")
    }

    @Test func aTilesPlaceInTheImageIsInSourcePixels() {
        let image = TestImages.gradient(width: 600, height: 400)
        let source = BufferTileSource(image: image, trueSize: PixelSize(width: 1200, height: 800), detailFactor: 2, tileSize: 128)
        // Level 1 of 600×400 is 300×200: tile (1,1) holds its pixels 128..<256 by 128..<200.
        let area = source.sourceArea(of: TileID(level: 1, column: 1, row: 1))

        // Each level-1 pixel is 2 grid pixels, each grid pixel 2 source pixels: ×4.
        #expect(area == CGRect(x: 512, y: 512, width: 128 * 4, height: 72 * 4), "\(area)")
    }
}
