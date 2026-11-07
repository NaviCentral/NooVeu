import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import NooVeuRender
import NooVeuCore

/// A scratch folder removed when the test ends.
final class ScratchFolder {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("nooveu-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

enum TilePictures {
    /// Deterministic noise: every pixel unrelated to its neighbours, so any seam or misplacement shows.
    static func noise(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let bytes = context.data!.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * context.bytesPerRow + x * 4
                for channel in 0..<3 {
                    state ^= state << 13; state ^= state >> 7; state ^= state << 17
                    bytes[offset + channel] = UInt8(truncatingIfNeeded: state >> 24)
                }
                bytes[offset + 3] = 255
            }
        }
        return context.makeImage()!
    }

    /// A smooth colour ramp: nothing in it is sharp, so a wrong stand-in or a black gap stands out.
    static func ramp(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(srgbRed: 0.25, green: 0.30, blue: 0.55, alpha: 1), CGColor(srgbRed: 0.65, green: 0.70, blue: 0.35, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        return context.makeImage()!
    }

    /// Writes `image` as a PNG (lossless, so what tiles serve is exactly what was drawn).
    static func writePNG(_ image: CGImage, to url: URL) {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
    }

    static func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return Int.max }
        var worst = 0
        for i in 0..<a.count where i % 4 != 3 { worst = max(worst, abs(Int(a[i]) - Int(b[i]))) }
        return worst
    }
}

@Suite("Tile rendering", .enabled(if: MTLCreateSystemDefaultDevice() != nil), .timeLimit(.minutes(2)))
@MainActor
struct TileRenderTests {
    let device = MTLCreateSystemDefaultDevice()!

    private func transform(imageSize: CGSize, view: CGSize = CGSize(width: 640, height: 480), zoom: CGFloat, panned: CGSize = .zero) -> ViewTransform {
        var t = ViewTransform(imageSize: imageSize, viewSize: view, backingScale: 1)
        t.setZoom(zoom)
        t.pan(by: panned)
        return t
    }

    /// A tile layer over a PNG of `image`, with `tileSize` px tiles.
    private func makeLayer(_ image: CGImage, tileSize: Int, folder: ScratchFolder, gpuBudget: Int = 256 << 20) throws -> TileLayer {
        let url = folder.file("image-\(UUID().uuidString).png")
        TilePictures.writePNG(image, to: url)
        let source = try TileSourceFactory.make(url: url, tileSize: tileSize)
        return TileLayer(source: source, device: device, gpuBudgetBytes: gpuBudget)
    }

    /// Updates the layer until every tile it wants is on the GPU (or fails after 30 s), and returns
    /// what to draw.
    private func settle(_ layer: TileLayer, _ transform: ViewTransform) async throws -> [TileQuad] {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            let quads = layer.update(for: transform)
            if layer.wantedTiles(for: transform).allSatisfy({ layer.cache.tile($0) != nil }) { return quads }
            try await Task.sleep(for: .milliseconds(5))
        }
        let wanted = layer.wantedTiles(for: transform)
        let missing = wanted.filter { layer.cache.tile($0) == nil }
        var states: [String] = []
        for id in missing.prefix(6) { states.append("\(id): \(await layer.loader.state(of: id))") }
        Issue.record("timed out waiting for tiles: \(missing.count) of \(wanted.count) missing; loader \(await layer.loader.statistics); \(states)")
        return layer.update(for: transform)
    }

    private func renderTiles(_ layer: TileLayer, _ transform: ViewTransform) async throws -> [UInt8] {
        let quads = try await settle(layer, transform)
        let renderer = try #require(ImageRenderer(device: device))
        return try renderer.renderOffscreen(base: nil, tiles: quads, transform: transform).bytes()
    }

    private func renderWhole(_ image: CGImage, _ transform: ViewTransform) async throws -> [UInt8] {
        let factory = try #require(TextureFactory(device: device))
        let renderer = try #require(ImageRenderer(device: device))
        let prepared = try await factory.makeTexture(from: image)
        return try renderer.renderOffscreen(texture: prepared.texture, transform: transform).bytes()
    }

    // MARK: Correctness against the whole-texture path

    @Test(arguments: [CGSize.zero, CGSize(width: -137, height: 61), CGSize(width: 300, height: -200)])
    func tilesAtActualPixelsAreIdenticalToTheWholeTexture(panned: CGSize) async throws {
        let folder = try ScratchFolder()
        let image = TilePictures.noise(width: 1000, height: 700)
        let layer = try makeLayer(image, tileSize: 256, folder: folder)
        let t = transform(imageSize: CGSize(width: 1000, height: 700), zoom: 1, panned: panned)

        let tiled = try await renderTiles(layer, t)
        let whole = try await renderWhole(image, t)

        #expect(tiled.contains { $0 != 0 }, "something was drawn")
        #expect(TilePictures.maxDifference(tiled, whole) <= 1)
    }

    @Test(arguments: [(0.37, 1), (0.2, 2), (0.6, 0)])
    func noSeamsShowBetweenTilesWhenZoomedOut(zoom: Double, level: Int) async throws {
        let folder = try ScratchFolder()
        // Noise is the worst case. The same image cut into tiles two different ways, so that no tile
        // edge falls where the other has one: any seam would show as a difference between the two.
        let image = TilePictures.noise(width: 1201, height: 903)
        let small = try makeLayer(image, tileSize: 128, folder: folder)
        let single = try makeLayer(image, tileSize: 192, folder: folder)
        let t = transform(imageSize: CGSize(width: 1201, height: 903), view: CGSize(width: 900, height: 700), zoom: CGFloat(zoom))
        #expect(small.source.grid.level(forZoom: zoom) == level, "the case exercises the level it names")

        let tiles = try await renderTiles(small, t)
        let otherTiles = try await renderTiles(single, t)

        #expect(small.wantedTiles(for: t).count > 4, "several tiles take part")
        #expect(single.source.grid.level(forZoom: zoom) == level)
        #expect(TilePictures.maxDifference(tiles, otherTiles) <= 2)
    }

    @Test func pixelPeepingDrawsTheSameSharpSquaresAsTheWholeTexture() async throws {
        let folder = try ScratchFolder()
        let image = TilePictures.noise(width: 700, height: 500)
        let layer = try makeLayer(image, tileSize: 64, folder: folder)
        let t = transform(imageSize: CGSize(width: 700, height: 500), view: CGSize(width: 320, height: 240), zoom: 3, panned: CGSize(width: -50, height: 20))

        let tiled = try await renderTiles(layer, t)
        let whole = try await renderWhole(image, t)

        #expect(TilePictures.maxDifference(tiled, whole) <= 1)
    }

    @Test func aReducedDetailSourceStillLandsWhereTheWholeImageWould() async throws {
        let folder = try ScratchFolder()
        let image = TilePictures.ramp(width: 1600, height: 1200)
        let url = folder.file("big.png")
        TilePictures.writePNG(image, to: url)
        // A budget that holds only half the detail: tiles are twice as coarse as the picture.
        let source = try TileSourceFactory.make(url: url, bufferBudget: 1600 * 1200, tileSize: 128)
        #expect(source.detailFactor > 1.9)
        let layer = TileLayer(source: source, device: device)
        let t = transform(imageSize: CGSize(width: 1600, height: 1200), view: CGSize(width: 800, height: 600), zoom: 0.5)

        let tiled = try await renderTiles(layer, t)
        let whole = try await renderWhole(image, t)

        // The picture is smooth, so the comparison is about placement, not filtering.
        #expect(TilePictures.maxDifference(tiled, whole) <= 8)
    }

    // MARK: What is requested and kept

    @Test func onlyTilesInViewAreWanted() throws {
        let folder = try ScratchFolder()
        let layer = try makeLayer(TilePictures.ramp(width: 4000, height: 3000), tileSize: 256, folder: folder)
        let t = transform(imageSize: CGSize(width: 4000, height: 3000), view: CGSize(width: 640, height: 480), zoom: 1)

        let wanted = layer.wantedTiles(for: t)

        // 640×480 at 1:1 touches at most 4 columns by 3 rows of 256 px tiles.
        #expect(wanted.count > 0 && wanted.count <= 12, "\(wanted.count) tiles")
        #expect(Set(wanted.map(\.level)) == [0])
    }

    @Test func aTileNotYetLoadedIsStoodInForByACoarserOne() async throws {
        let folder = try ScratchFolder()
        let image = TilePictures.ramp(width: 2000, height: 1500)
        let layer = try makeLayer(image, tileSize: 128, folder: folder)
        let zoomedOut = transform(imageSize: CGSize(width: 2000, height: 1500), view: CGSize(width: 700, height: 500), zoom: 0.4)
        _ = try await settle(layer, zoomedOut)

        // Zoom in a little: level 0 tiles are not here yet, but the level 1 ones cover the view.
        let zoomedIn = transform(imageSize: CGSize(width: 2000, height: 1500), view: CGSize(width: 700, height: 500), zoom: 0.8)
        let quads = layer.update(for: zoomedIn)

        #expect(!quads.isEmpty)
        #expect(quads.allSatisfy { $0.id.level >= 1 }, "stand-ins from coarser levels")
        let renderer = try #require(ImageRenderer(device: device))
        let frame = try renderer.renderOffscreen(base: nil, tiles: quads, transform: zoomedIn)
        let bytes = frame.bytes()
        for (x, y) in [(10, 10), (350, 250), (690, 490), (100, 400)] {
            let p = frame.pixel(x: x, y: y, in: bytes)
            #expect(p.r > 40 && p.g > 40 && p.b > 40, "no hole at (\(x), \(y))")
        }
    }

    @Test func coarseStandInsDrawBeneathFinerTiles() async throws {
        let folder = try ScratchFolder()
        let size = CGSize(width: 2000, height: 1500)
        let layer = try makeLayer(TilePictures.ramp(width: 2000, height: 1500), tileSize: 128, folder: folder)
        // Level 1 for the whole picture; then level 0 for a small part of it only.
        _ = try await settle(layer, transform(imageSize: size, view: CGSize(width: 700, height: 500), zoom: 0.4))
        _ = try await settle(layer, transform(imageSize: size, view: CGSize(width: 200, height: 150), zoom: 1))
        // A wider view at level 0: the small part is there in detail, the rest only as level 1.
        let wide = transform(imageSize: size, view: CGSize(width: 700, height: 500), zoom: 0.8)

        let quads = layer.update(for: wide)

        let levels = quads.map(\.id.level)
        #expect(levels.contains(0) && levels.contains(1), "a mix of detail and stand-ins: \(Set(levels))")
        #expect(levels == levels.sorted(by: >), "coarsest first, so finer tiles draw over stand-ins")
    }

    @Test func theGPUBudgetHoldsWhileTheViewMovesOverTheWholeImage() async throws {
        let folder = try ScratchFolder()
        // 256 px tiles are about 0.27 MB; a budget of 2 MB holds seven.
        let layer = try makeLayer(TilePictures.ramp(width: 2048, height: 1536), tileSize: 256, folder: folder, gpuBudget: 2 << 20)
        var peak = 0
        for step in 0..<12 {
            let t = transform(imageSize: CGSize(width: 2048, height: 1536), view: CGSize(width: 300, height: 200), zoom: 1,
                              panned: CGSize(width: CGFloat(-step * 150), height: CGFloat(-step * 90)))
            _ = try await settle(layer, t)
            peak = max(peak, layer.cache.residentBytes)
        }

        #expect(layer.cache.residentBytes <= 2 << 20 + 4 * 300_000, "the budget, plus tiles in use that cannot be dropped")
        #expect(peak < 4 << 20, "never grew far beyond the budget: \(peak)")
        #expect(layer.cache.count < 24, "far fewer than the whole image's \(layer.source.grid.columns(level: 0) * layer.source.grid.rows(level: 0)) tiles")
    }

    @Test func askingEveryFrameDoesNotReloadOrReuploadTilesAlreadyOnTheGPU() async throws {
        let folder = try ScratchFolder()
        let layer = try makeLayer(TilePictures.ramp(width: 1000, height: 800), tileSize: 256, folder: folder)
        let t = transform(imageSize: CGSize(width: 1000, height: 800), zoom: 1)
        var notifications = 0
        layer.onTilesChanged = { notifications += 1 }
        _ = try await settle(layer, t)
        // Every tile's arrival is announced on the main actor a moment after it is on the GPU.
        let wanted = layer.wantedTiles(for: t).count
        let deadline = ContinuousClock.now + .seconds(10)
        while notifications < wanted, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(notifications == wanted)
        let before = await layer.loader.statistics
        let announced = notifications

        for _ in 0..<300 { _ = layer.update(for: t) }
        try await Task.sleep(for: .milliseconds(100))

        let after = await layer.loader.statistics
        #expect(after.decodesStarted == before.decodesStarted, "no decodes: \(after) vs \(before)")
        #expect(notifications == announced, "nothing was uploaded again")
    }

    @Test func closingStopsDrawingAndFreesTheGPU() async throws {
        let folder = try ScratchFolder()
        let layer = try makeLayer(TilePictures.ramp(width: 1000, height: 800), tileSize: 256, folder: folder)
        let t = transform(imageSize: CGSize(width: 1000, height: 800), zoom: 1)
        _ = try await settle(layer, t)
        #expect(layer.cache.count > 0)

        layer.close()

        #expect(layer.cache.count == 0)
        #expect(layer.update(for: t).isEmpty)
    }

    @Test func theLayerTellsTheViewWhenATileArrives() async throws {
        let folder = try ScratchFolder()
        let layer = try makeLayer(TilePictures.ramp(width: 1000, height: 800), tileSize: 256, folder: folder)
        let t = transform(imageSize: CGSize(width: 1000, height: 800), zoom: 1)
        var notifications = 0
        layer.onTilesChanged = { notifications += 1 }

        _ = try await settle(layer, t)
        // The announcement follows the upload by a hop to the main actor: wait for it, with a deadline.
        let wanted = layer.wantedTiles(for: t).count
        let deadline = ContinuousClock.now + .seconds(10)
        while notifications < wanted, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }

        #expect(notifications == wanted, "one announcement per tile that arrived")
    }

    @Test(arguments: [(1, 1.0), (2, 1.0), (2, 3.0), (2, 0.5)])
    func tilesMatchTheWholeTextureOnAHiDPIDisplayWithAnOddSizeAndFractionalPans(scale: Int, zoom: Double) async throws {
        let folder = try ScratchFolder()
        let image = TilePictures.noise(width: 601, height: 453)
        let layer = try makeLayer(image, tileSize: 128, folder: folder)
        // An odd image in an odd view: the device-pixel snap shifts the image by a fraction of a point.
        var t = ViewTransform(imageSize: CGSize(width: 601, height: 453), viewSize: CGSize(width: 151, height: 111), backingScale: CGFloat(scale))
        t.setZoom(CGFloat(zoom))
        t.pan(by: CGSize(width: -13.3, height: 7.7))

        let tiled = try await renderTiles(layer, t)
        let whole = try await renderWhole(image, t)

        // Level 0 (zoom 1 and above) is exact. Zoomed out, the tiles' level is filtered differently from
        // the whole texture's mipmaps, so only the placement is compared, loosely.
        #expect(TilePictures.maxDifference(tiled, whole) <= (zoom >= 1 ? 1 : 255))
        #expect(tiled.contains { $0 != 0 })
        if zoom < 1 {
            // Placement: the average colour of the frame is close.
            func mean(_ b: [UInt8]) -> Double { Double(b.enumerated().filter { $0.offset % 4 != 3 }.reduce(0) { $0 + Int($1.element) }) / Double(b.count * 3 / 4) }
            #expect(abs(mean(tiled) - mean(whole)) < 6)
        }
    }

    @Test func aLayerDroppedWithoutClosingStopsItsLoader() async throws {
        let folder = try ScratchFolder()
        var layer: TileLayer? = try makeLayer(TilePictures.ramp(width: 1000, height: 800), tileSize: 256, folder: folder)
        let loader = layer!.loader
        _ = try await settle(layer!, transform(imageSize: CGSize(width: 1000, height: 800), zoom: 1))
        let started = await loader.statistics.decodesStarted

        layer = nil
        try await Task.sleep(for: .milliseconds(100))  // the deinit's closing task runs
        // A closed loader ignores requests; an open one would start decoding this tile.
        let unwanted = TileID(level: 0, column: 3, row: 2)
        #expect(await loader.state(of: unwanted) == .unknown)
        await loader.want([unwanted])
        try await Task.sleep(for: .milliseconds(200))

        #expect(await loader.statistics.decodesStarted == started, "no new decodes after the layer is gone")
        #expect(await loader.state(of: unwanted) == .unknown)
    }
}
