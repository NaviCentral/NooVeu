import CoreGraphics
import Metal
import Testing
@testable import NooVeuRender
import NooVeuCore

@Suite("TileTextureCache", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct TileTextureCacheTests {
    let device = MTLCreateSystemDefaultDevice()!

    private func id(_ n: Int) -> TileID { TileID(level: 0, column: n, row: 0) }
    private let rect = PixelRect(x: 0, y: 0, width: 64, height: 64)

    /// A 64×64 texture: 16 384 bytes.
    private func texture() -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        return device.makeTexture(descriptor: descriptor)!
    }

    @Test func aTileIsFoundAfterItIsInserted() {
        let cache = TileTextureCache(device: device, budgetBytes: 1 << 20)

        cache.insert(id(1), texture: texture(), paddedRect: rect)

        #expect(cache.tile(id(1))?.paddedRect == rect)
        #expect(cache.tile(id(2)) == nil)
        #expect(cache.residentIDs == [id(1)])
        #expect(cache.residentBytes == 64 * 64 * 4)
    }

    @Test func theLeastRecentlyUsedTileGoesFirstNotTheOldest() {
        let cache = TileTextureCache(device: device, budgetBytes: 3 * 16_384)
        for n in 0..<3 { cache.insert(id(n), texture: texture(), paddedRect: rect) }  // 0 is the oldest
        cache.markUsed([id(1), id(2)])
        cache.markUsed([id(0), id(2)])  // 0 was used most recently after all; 1 least recently

        cache.insert(id(3), texture: texture(), paddedRect: rect)

        #expect(cache.residentIDs == [id(0), id(2), id(3)], "1 went, not 0 (which first-in-first-out would drop)")
        #expect(cache.residentBytes <= 3 * 16_384)
    }

    @Test func tilesNotUsedSinceTheSameCallGoInTheOrderTheyWereLastTouched() {
        let cache = TileTextureCache(device: device, budgetBytes: 4 * 16_384)
        for n in 0..<4 { cache.insert(id(n), texture: texture(), paddedRect: rect) }
        cache.markUsed([id(3), id(2), id(1), id(0)])  // all in one call, touched in this order: 3 longest ago
        cache.markUsed([id(9)])  // none of these in use any more

        cache.insert(id(4), texture: texture(), paddedRect: rect)

        #expect(cache.residentIDs == [id(0), id(1), id(2), id(4)], "3 was touched first, so it goes, not an arbitrary one")
    }

    @Test func aClosedCacheRefusesTilesThatArriveLate() {
        let cache = TileTextureCache(device: device, budgetBytes: 1 << 20)
        cache.insert(id(1), texture: texture(), paddedRect: rect)

        cache.close()
        cache.insert(id(2), texture: texture(), paddedRect: rect)  // an upload that was under way

        #expect(cache.count == 0 && cache.residentBytes == 0)
    }

    @Test func theChangeCountMovesOnlyWhenWhatIsResidentChanges() {
        let cache = TileTextureCache(device: device, budgetBytes: 1 << 20)
        let start = cache.changeCount

        cache.insert(id(1), texture: texture(), paddedRect: rect)
        let afterInsert = cache.changeCount
        cache.markUsed([id(1)])
        _ = cache.tile(id(1))

        #expect(afterInsert > start)
        #expect(cache.changeCount == afterInsert, "using tiles does not change what is resident")
    }

    @Test func tilesInUseAreNeverEvicted() {
        let cache = TileTextureCache(device: device, budgetBytes: 2 * 16_384)
        for n in 0..<4 { cache.insert(id(n), texture: texture(), paddedRect: rect) }
        // 0-3 all arrived since the last markUsed, so all are in use: nothing can go.
        #expect(cache.count == 4, "the budget gives way to tiles in use")

        cache.markUsed([id(0), id(1)])
        cache.insert(id(4), texture: texture(), paddedRect: rect)

        // 2 and 3 are no longer in use and go; 4 is new and 0 and 1 are in use.
        #expect(cache.residentIDs == [id(0), id(1), id(4)], "only the unused ones were dropped, though that is still over budget")
    }

    @Test func replacingATileDoesNotCountItsBytesTwice() {
        let cache = TileTextureCache(device: device, budgetBytes: 1 << 20)

        cache.insert(id(1), texture: texture(), paddedRect: rect)
        cache.insert(id(1), texture: texture(), paddedRect: rect)

        #expect(cache.count == 1)
        #expect(cache.residentBytes == 16_384)
    }

    @Test func removeAllEmptiesTheCache() {
        let cache = TileTextureCache(device: device, budgetBytes: 1 << 20)
        cache.insert(id(1), texture: texture(), paddedRect: rect)

        cache.removeAll()

        #expect(cache.count == 0 && cache.residentBytes == 0)
    }

    @Test func anUploadedTileHoldsTheBitmapsPixels() async throws {
        let folder = try ScratchFolder()
        let url = folder.file("a.png")
        TilePictures.writePNG(TilePictures.noise(width: 200, height: 150), to: url)
        let source = try TileSourceFactory.make(url: url, tileSize: 64)
        let bitmap = try await source.tile(TileID(level: 0, column: 1, row: 1))
        let cache = TileTextureCache(device: device)

        let texture = try #require(cache.makeTexture(for: bitmap))

        #expect(texture.width == bitmap.image.width && texture.height == bitmap.image.height)
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        // Read the bitmap back through the same BGRA layout.
        let context = CGContext(data: nil, width: texture.width, height: texture.height, bitsPerComponent: 8, bytesPerRow: texture.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(bitmap.image, in: CGRect(x: 0, y: 0, width: texture.width, height: texture.height))
        let expected = Array(UnsafeBufferPointer(start: context.data!.bindMemory(to: UInt8.self, capacity: bytes.count), count: bytes.count))
        #expect(bytes == expected)
        #expect(bytes.contains { $0 > 10 && $0 < 245 }, "not an empty texture")
    }

    @Test func aBitmapInAnotherLayoutIsRefusedNotMisread() throws {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bitmap = TileBitmap(id: id(0), image: context.makeImage()!, paddedRect: PixelRect(x: 0, y: 0, width: 16, height: 16))

        #expect(TileTextureCache(device: device).makeTexture(for: bitmap) == nil, "RGBA bytes would draw with red and blue swapped")
    }

    @Test func manyThreadsUsingTheCacheAtOnceKeepItConsistent() async {
        let cache = TileTextureCache(device: device, budgetBytes: 8 * 16_384)
        nonisolated(unsafe) let textures = (0..<8).map { _ in texture() }
        let rect = self.rect
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for round in 0..<200 {
                        let n = (worker * 31 + round) % 40
                        cache.insert(TileID(level: 0, column: n, row: 0), texture: textures[worker], paddedRect: rect)
                        _ = cache.tile(TileID(level: 0, column: (n + 7) % 40, row: 0))
                        if round % 20 == 0 { cache.markUsed((0..<4).map { TileID(level: 0, column: ($0 + round) % 40, row: 0) }) }
                    }
                }
            }
        }

        #expect(cache.residentBytes == cache.count * 16_384, "the byte count matches what is held")
    }
}
