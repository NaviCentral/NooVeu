import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import NooVeuCore

@Suite("LargeImagePolicy")
struct LargeImagePolicyTests {
    @Test func onlyImagesAboveTheThresholdAreTiled() {
        #expect(!LargeImagePolicy.shouldTile(sourceSize: PixelSize(width: 6000, height: 4000)), "24 MP stays on the whole-texture path")
        #expect(!LargeImagePolicy.shouldTile(sourceSize: PixelSize(width: 8192, height: 8192)))
        #expect(LargeImagePolicy.shouldTile(sourceSize: PixelSize(width: 8193, height: 100)), "the longest side decides")
        #expect(LargeImagePolicy.shouldTile(sourceSize: PixelSize(width: 100, height: 12240)))
        #expect(LargeImagePolicy.shouldTile(sourceSize: PixelSize(width: 12240, height: 8160)))
    }

    @Test func aHostileHeaderClaimingAnAbsurdSizeDoesNotOverflow() {
        // The size comes from the file. 2 billion squared times 4 bytes is beyond Int.
        let factor = LargeImagePolicy.detailFactor(for: PixelSize(width: 2_000_000_000, height: 2_000_000_000), budgetBytes: 512 << 20)

        #expect(factor == 64, "the most reduction there is")
    }

    @Test func theDetailFactorIsTheSmallestPowerOfTwoThatFitsTheBudget() {
        let budget = 512 << 20
        #expect(LargeImagePolicy.detailFactor(for: PixelSize(width: 12240, height: 8160), budgetBytes: budget) == 1, "100 MP is 399 MB")
        #expect(LargeImagePolicy.detailFactor(for: PixelSize(width: 16384, height: 16384), budgetBytes: budget) == 2, "1 GB, so half size")
        #expect(LargeImagePolicy.detailFactor(for: PixelSize(width: 40_000, height: 20_000), budgetBytes: budget) == 4, "3.2 GB")
    }

    @Test func theFactorIsExactAtTheBoundary() {
        // 100×100×4 = 40000 bytes.
        #expect(LargeImagePolicy.detailFactor(for: PixelSize(width: 100, height: 100), budgetBytes: 40_000) == 1)
        #expect(LargeImagePolicy.detailFactor(for: PixelSize(width: 100, height: 100), budgetBytes: 39_999) == 2)
        #expect(LargeImagePolicy.detailFactor(for: PixelSize(width: 101, height: 101), budgetBytes: 40_000) == 2)
    }

    @Test func aHopelesslySmallBudgetStopsAtTheLimit() {
        #expect(LargeImagePolicy.detailFactor(for: PixelSize(width: 40_000, height: 20_000), budgetBytes: 0) == 64)
        #expect(LargeImagePolicy.detailFactor(for: PixelSize(width: 40_000, height: 20_000), budgetBytes: -5) == 64)
        #expect(LargeImagePolicy.detailFactor(for: PixelSize(width: 1, height: 1), budgetBytes: 0) == 64)
    }
}

@Suite("decodeForTiling")
struct DecodeForTilingTests {
    @Test func fullDetailHasNoTextureCap() throws {
        // Wider than the 16384 px texture limit: the normal decoder reduces it; tiling must not.
        let folder = try TemporaryFolder()
        let url = TestImages.write(width: 17_000, height: 8, to: folder.file("wide.jpg"), type: "public.jpeg")

        let decoded = try ImageDecoder.decodeForTiling(url)

        #expect(decoded.pixelSize == PixelSize(width: 17_000, height: 8))
        #expect(decoded.sourcePixelSize == PixelSize(width: 17_000, height: 8))
        #expect(decoded.cgImage.isMetalUploadable, "fully decoded, in a layout Metal takes")
    }

    @Test func aReducedDecodeIsSmallerButRemembersTheTrueSize() throws {
        let folder = try TemporaryFolder()
        let url = TestImages.write(width: 400, height: 300, to: folder.file("a.jpg"), type: "public.jpeg")

        let half = try ImageDecoder.decodeForTiling(url, detailFactor: 2)

        #expect(half.pixelSize == PixelSize(width: 200, height: 150))
        #expect(half.sourcePixelSize == PixelSize(width: 400, height: 300))
    }

    @Test func aReducedDecodeWorksForFormatsWithoutFractionalDecoding() throws {
        let folder = try TemporaryFolder()
        let url = TestImages.write(width: 400, height: 300, to: folder.file("a.png"), type: "public.png")

        let quarter = try ImageDecoder.decodeForTiling(url, detailFactor: 4)

        #expect(quarter.pixelSize == PixelSize(width: 100, height: 75))
        #expect(quarter.sourcePixelSize == PixelSize(width: 400, height: 300))
    }

    @Test func aJpegWhoseShortSideIsSmallerThanTheFractionStillComesOutSmall() throws {
        // ImageIO ignores the fraction for such a file and returns it whole, which would defeat the
        // memory limit: the decoder must notice and reduce it another way.
        let folder = try TemporaryFolder()
        let url = TestImages.write(width: 3000, height: 3, to: folder.file("sliver.jpg"), type: "public.jpeg")

        let reduced = try ImageDecoder.decodeForTiling(url, detailFactor: 4)

        #expect(reduced.pixelSize.longestSide <= 750 + 750 / 8, "got \(reduced.pixelSize)")
        #expect(reduced.pixelSize.longestSide > 0)
        #expect(reduced.sourcePixelSize == PixelSize(width: 3000, height: 3))
    }

    @Test func orientationIsApplied() throws {
        let folder = try TemporaryFolder()
        let url = TestImages.write(width: 40, height: 20, to: folder.file("r.jpg"), type: "public.jpeg",
                                   properties: [kCGImagePropertyOrientation: 6])

        let decoded = try ImageDecoder.decodeForTiling(url)

        #expect(decoded.pixelSize == PixelSize(width: 20, height: 40))
    }

    @Test func aFileThatIsNotAnImageIsRefused() throws {
        let folder = try TemporaryFolder()
        try folder.touch("fake.jpg", contents: "nope")

        #expect(throws: DecodeError.self) { _ = try ImageDecoder.decodeForTiling(folder.file("fake.jpg")) }
        #expect(throws: DecodeError.self) { _ = try ImageDecoder.decodeForTiling(folder.file("missing.jpg")) }
    }
}

@Suite("TileSourceFactory")
struct TileSourceFactoryTests {
    @Test func heicIsServedByRegionDecoding() throws {
        let folder = try TemporaryFolder()
        let url = TestImages.writeGradient(width: 300, height: 200, smooth: true, to: folder.file("a.heic"), type: "public.heic")

        // A generous time budget: this checks the choice by format, not the speed of the machine.
        let source = try TileSourceFactory.make(url: url, tileSize: 64, regionTileBudget: .seconds(30))

        #expect(source is RegionTileSource)
        #expect(source.retainedBytes == 0)
        #expect(source.detailFactor == 1)
    }

    @Test func aRegionSourceThatIsTooSlowIsReplacedByABuffer() throws {
        let folder = try TemporaryFolder()
        let url = TestImages.writeGradient(width: 300, height: 200, smooth: true, to: folder.file("a.heic"), type: "public.heic")

        // No tile can take zero time: this is a file whose region decoding does not pay.
        let source = try TileSourceFactory.make(url: url, tileSize: 64, regionTileBudget: .zero)

        #expect(source is BufferTileSource)
        #expect(source.retainedBytes >= 300 * 200 * 4)
    }

    @Test(arguments: [("public.jpeg", "jpg"), ("public.png", "png"), ("public.tiff", "tif")])
    func formatsWithoutRegionDecodingAreDecodedOnceIntoABuffer(type: String, ext: String) throws {
        let folder = try TemporaryFolder()
        let url = TestImages.writeGradient(width: 300, height: 200, to: folder.file("a.\(ext)"), type: type)

        let source = try TileSourceFactory.make(url: url, tileSize: 64)

        #expect(source is BufferTileSource)
        #expect(source.retainedBytes >= 300 * 200 * 4)
        #expect(source.grid.levelSize(0) == PixelSize(width: 300, height: 200))
        #expect(source.detailFactor == 1)
    }

    @Test func anImageTooBigForTheBudgetIsHeldAtReducedDetail() throws {
        let folder = try TemporaryFolder()
        let url = TestImages.writeGradient(width: 200, height: 100, to: folder.file("big.png"), type: "public.png")

        // 200×100×4 = 80000 bytes: over a 20000-byte budget, so it is held at half size (20000 bytes).
        let source = try TileSourceFactory.make(url: url, bufferBudget: 20_000, tileSize: 32)

        #expect(source.grid.levelSize(0) == PixelSize(width: 100, height: 50))
        // Each row is padded to the system's alignment (up to 64 bytes), which the budget does not count.
        #expect(source.retainedBytes <= 20_000 + 64 * 50, "\(source.retainedBytes) bytes")
        #expect(abs(source.detailFactor - 2) < 0.05, "half the detail: \(source.detailFactor)")
    }

    @Test func aReducedSourceStillServesTiles() async throws {
        let folder = try TemporaryFolder()
        let url = TestImages.writeGradient(width: 200, height: 100, to: folder.file("big.png"), type: "public.png")
        let source = try TileSourceFactory.make(url: url, bufferBudget: 20_000, tileSize: 32)

        let tile = try await source.tile(TileID(level: 0, column: 1, row: 1))

        #expect(tile.image.isMetalUploadable)
        #expect(tile.paddedRect.width > 0)
    }

    @Test func aFileThatIsNotAnImageIsRefused() throws {
        let folder = try TemporaryFolder()
        try folder.touch("fake.heic", contents: "nope")

        #expect(throws: DecodeError.self) { _ = try TileSourceFactory.make(url: folder.file("fake.heic")) }
        #expect(throws: DecodeError.self) { _ = try TileSourceFactory.make(url: folder.file("missing.png")) }
    }

    @Test func theRegionFormatsAreTheHeifFamily() {
        for type in ["public.heic", "public.heics", "public.heif", "public.avif", "public.avis", "public.avci"] {
            #expect(TileSourceFactory.regionTypes.contains(type), "\(type)")
        }
        for type in ["public.jpeg", "public.png", "public.tiff", "com.compuserve.gif", "org.webmproject.webp"] {
            #expect(!TileSourceFactory.regionTypes.contains(type), "\(type)")
        }
    }
}
