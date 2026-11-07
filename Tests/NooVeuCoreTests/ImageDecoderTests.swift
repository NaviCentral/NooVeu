import Foundation
import ImageIO
import Testing
@testable import NooVeuCore

@Suite("ImageDecoder")
struct ImageDecoderTests {
    @Test func decodesFullResolution() throws {
        let folder = try TemporaryFolder()
        let url = TestImages.write(width: 64, height: 32, to: folder.file("wide.png"))

        let image = try ImageDecoder.decode(url)

        #expect(image.pixelSize == PixelSize(width: 64, height: 32))
        #expect(image.sourcePixelSize == PixelSize(width: 64, height: 32))
        #expect(!image.isDownsampled)
        #expect(image.typeIdentifier == "public.png")
    }

    @Test func downsamplesToTheRequestedLongestSide() throws {
        // HEIC takes the thumbnail path, which scales exactly; PNG is deliberately decoded
        // at full size (see DecodeStrategy).
        let folder = try TemporaryFolder()
        let url = TestImages.write(width: 64, height: 32, to: folder.file("wide.heic"), type: "public.heic")

        let image = try ImageDecoder.decode(url, options: .fitting(16))

        #expect(image.pixelSize == PixelSize(width: 16, height: 8))
        #expect(image.sourcePixelSize == PixelSize(width: 64, height: 32))
        #expect(image.isDownsampled)
    }

    /// Which colour is displayed in each corner for each EXIF orientation, for a stored picture
    /// that is red top-left, green top-right, blue bottom-left and yellow bottom-right.
    /// Worked out from the EXIF definition of each orientation (where the stored first row and
    /// first column end up), independently of the decoder's transform matrices.
    /// Order: top-left, top-right, bottom-left, bottom-right.
    static let displayedCorners: [Int: [Quadrant]] = [
        1: [.red, .green, .blue, .yellow],
        2: [.green, .red, .yellow, .blue],   // mirrored left-right
        3: [.yellow, .blue, .green, .red],   // rotated 180°
        4: [.blue, .yellow, .red, .green],   // mirrored top-bottom
        5: [.red, .blue, .green, .yellow],   // transposed
        6: [.blue, .red, .yellow, .green],   // rotated 90° clockwise
        7: [.yellow, .green, .blue, .red],   // transversed
        8: [.green, .yellow, .red, .blue],   // rotated 90° anticlockwise
    ]

    enum Format: String, CaseIterable, CustomTestStringConvertible {
        case jpeg = "public.jpeg", heic = "public.heic"
        var fileExtension: String { self == .jpeg ? "jpg" : "heic" }
        var testDescription: String { fileExtension }
    }

    @Test(arguments: Format.allCases, 1...8)
    func appliesEveryExifOrientation(format: Format, orientation: Int) throws {
        let folder = try TemporaryFolder()
        let url = TestImages.writeQuadrants(width: 64, height: 32, to: folder.file("o.\(format.fileExtension)"),
                                            type: format.rawValue,
                                            properties: [kCGImagePropertyOrientation: orientation])
        let swapped = orientation >= 5
        let expected = Self.displayedCorners[orientation]!

        // At full size both formats are decoded whole (subsample factor 1, the source being no
        // larger than the target); at `.fitting(32)` JPEG is subsampled and HEIC takes the
        // thumbnail path.
        for options in [DecodeOptions.fullResolution, .fitting(32)] {
            let image = try ImageDecoder.decode(url, options: options)

            #expect(image.sourcePixelSize == PixelSize(width: swapped ? 32 : 64, height: swapped ? 64 : 32))
            #expect(image.pixelSize.width * image.sourcePixelSize.height
                    == image.pixelSize.height * image.sourcePixelSize.width, "aspect ratio kept")
            #expect(TestImages.quarterColors(of: image.cgImage) == expected,
                    "\(format) orientation \(orientation) at \(options)")
        }
    }

    @Test func appliesOrientationToPNGWhenImageIOKeepsIt() throws {
        // PNG has no native orientation field, so only run if ImageIO reads one back.
        let folder = try TemporaryFolder()
        let url = TestImages.writeQuadrants(width: 64, height: 32, to: folder.file("o.png"), type: "public.png",
                                            properties: [kCGImagePropertyOrientation: 6])
        guard ImageDecoder.probe(url)?.orientation == .right else { return }

        let image = try ImageDecoder.decode(url)

        #expect(TestImages.quarterColors(of: image.cgImage) == Self.displayedCorners[6]!)
    }

    @Test func probeReadsSizeWithoutDecoding() throws {
        let folder = try TemporaryFolder()
        let url = TestImages.write(width: 40, height: 30, to: folder.file("p.jpg"), type: "public.jpeg",
                                   properties: [kCGImagePropertyOrientation: 6])

        let probe = try #require(ImageDecoder.probe(url))

        #expect(probe.orientedSize == PixelSize(width: 30, height: 40))
        #expect(probe.orientation == .right)
        #expect(probe.frameCount == 1)
    }

    @Test func thumbnailFitsTheRequestedSize() throws {
        let folder = try TemporaryFolder()
        let url = TestImages.write(width: 400, height: 100, to: folder.file("t.jpg"), type: "public.jpeg")

        let thumbnail = try ImageDecoder.thumbnail(url, maxPixelSize: 100)

        #expect(thumbnail.pixelSize.longestSide == 100)
    }

    @Test func rejectsATextFileNamedLikeAnImage() throws {
        let folder = try TemporaryFolder()
        try folder.touch("fake.jpg", contents: "not an image")

        #expect(throws: DecodeError.self) {
            try ImageDecoder.decode(folder.file("fake.jpg"))
        }
    }

    @Test func rejectsAnEmptyFile() throws {
        let folder = try TemporaryFolder()
        try folder.touch("empty.png")

        #expect(throws: DecodeError.self) {
            try ImageDecoder.decode(folder.file("empty.png"))
        }
    }

    @Test func truncatedFileIsRejectedOrShownAtItsTrueSize() throws {
        let folder = try TemporaryFolder()
        let url = TestImages.write(width: 64, height: 64, to: folder.file("whole.png"))
        let data = try Data(contentsOf: url)
        try data.prefix(40).write(to: folder.file("cut.png"))

        do {
            let image = try ImageDecoder.decode(folder.file("cut.png"))
            #expect(image.sourcePixelSize == PixelSize(width: 64, height: 64))
        } catch is DecodeError {
            // Rejecting a cut-off file is equally correct; any other error type would be a bug.
        }
    }

    @Test func tinyAndNonPositiveTargetsNeverFail() throws {
        // `maxPixelSize` is a hint. ImageIO's thumbnail call refuses a 1-pixel HEIC, so that
        // case decodes the whole image instead of failing; JPEG subsamples down to 1/8.
        let folder = try TemporaryFolder()
        let jpeg = TestImages.write(width: 64, height: 32, to: folder.file("a.jpg"), type: "public.jpeg")
        let heic = TestImages.write(width: 64, height: 32, to: folder.file("a.heic"), type: "public.heic")

        for side in [-5, 0, 1] {
            let small = try ImageDecoder.decode(jpeg, options: .fitting(side))
            #expect(small.pixelSize.longestSide < 64, "jpeg fitting(\(side))")

            let any = try ImageDecoder.decode(heic, options: .fitting(side))
            #expect(any.pixelSize.longestSide >= 1 && any.pixelSize.longestSide <= 64, "heic fitting(\(side))")
            #expect(any.sourcePixelSize == PixelSize(width: 64, height: 32))
        }
    }

    @Test func decodeOptionsNeverHoldAnImpossibleSize() {
        #expect(DecodeOptions(maxPixelSize: -3).maxPixelSize == 1)
        #expect(DecodeOptions(maxPixelSize: 0).maxPixelSize == 1)
        #expect(DecodeOptions(maxPixelSize: 500).maxPixelSize == 500)
        #expect(DecodeOptions(maxPixelSize: nil).maxPixelSize == nil)
        #expect(DecodeOptions.fullResolution.maxPixelSize == nil)
    }

    @Test func aThumbnailRequestOfZeroOrLessIsClampedNotUnlimited() throws {
        let folder = try TemporaryFolder()
        let url = TestImages.write(width: 64, height: 32, to: folder.file("a.jpg"), type: "public.jpeg")

        for side in [-1, 0] {
            #expect(try ImageDecoder.thumbnail(url, maxPixelSize: side).pixelSize.longestSide < 64, "side \(side)")
        }
    }

    @Test func anEmbeddedPreviewIsUsedOnlyWhenItIsBigEnough() throws {
        let folder = try TemporaryFolder()
        let url = TestImages.write(width: 800, height: 600, to: folder.file("camera.jpg"), type: "public.jpeg",
                                   properties: [kCGImageDestinationEmbedThumbnail: true])

        let big = try ImageDecoder.thumbnail(url, maxPixelSize: 400)
        let small = try ImageDecoder.thumbnail(url, maxPixelSize: 100)

        // A camera-sized preview (about 160 px) would be blurry in a 400 px cell: decode instead.
        #expect(big.pixelSize.longestSide >= 300, "got \(big.pixelSize)")
        #expect(small.pixelSize.longestSide >= 75 && small.pixelSize.longestSide <= 170, "got \(small.pixelSize)")
    }

    @Test func decodedJPEGIsReadyForTheGPU() throws {
        let folder = try TemporaryFolder()
        let url = TestImages.write(width: 64, height: 32, to: folder.file("a.jpg"), type: "public.jpeg")

        let image = try ImageDecoder.decode(url)

        #expect(image.cgImage.isMetalUploadable)
    }
}

@Suite("DecodeStrategy")
struct DecodeStrategyTests {
    @Test func usesTheSourceAsIsWhenItAlreadyFits() {
        #expect(DecodeStrategy.choose(typeIdentifier: "public.jpeg", sourceLongestSide: 3000, target: 3456) == .subsample(factor: 1))
        #expect(DecodeStrategy.choose(typeIdentifier: "public.heic", sourceLongestSide: 3000, target: 3456) == .subsample(factor: 1))
    }

    @Test func jpegSubsamplesByTheLargestFactorThatStaysNearTheTarget() {
        // 6000 px at a 3456 target: 1/2 gives 3000 (≥ ¾ of 3456 = 2592); 1/4 gives 1500 (too small).
        #expect(DecodeStrategy.choose(typeIdentifier: "public.jpeg", sourceLongestSide: 6000, target: 3456) == .subsample(factor: 2))
        #expect(DecodeStrategy.choose(typeIdentifier: "public.jpeg", sourceLongestSide: 12240, target: 3456) == .subsample(factor: 4))
        #expect(DecodeStrategy.choose(typeIdentifier: "public.jpeg", sourceLongestSide: 40000, target: 3456) == .subsample(factor: 8))
    }

    @Test func heicAndAvifUseTheThumbnailPath() {
        for type in ["public.heic", "public.avif", "public.heif"] {
            #expect(DecodeStrategy.choose(typeIdentifier: type, sourceLongestSide: 6000, target: 3456) == .thumbnail(maxPixelSize: 3456))
        }
    }

    @Test func everyHeifFamilyTypeUsesTheThumbnailPath() {
        for type in ["public.heics", "public.avis", "public.avci"] {
            #expect(DecodeStrategy.choose(typeIdentifier: type, sourceLongestSide: 6000, target: 3456) == .thumbnail(maxPixelSize: 3456), "\(type)")
        }
    }

    @Test func otherFormatsDecodeWholeUnlessTheyExceedTheTextureLimit() {
        #expect(DecodeStrategy.choose(typeIdentifier: "public.png", sourceLongestSide: 6000, target: 3456) == .subsample(factor: 1))
        #expect(DecodeStrategy.choose(typeIdentifier: "public.png", sourceLongestSide: 20000, target: 16384) == .thumbnail(maxPixelSize: 16384))
        #expect(DecodeStrategy.choose(typeIdentifier: nil, sourceLongestSide: 6000, target: 3456) == .subsample(factor: 1))
    }

    @Test func aSubsampledResultNeverExceedsTheTextureLimit() {
        // 40000 / 2 = 20000 would be too big for a texture, so a 16384 target falls to the thumbnail path.
        #expect(DecodeStrategy.choose(typeIdentifier: "public.jpeg", sourceLongestSide: 40000, target: 16384) == .thumbnail(maxPixelSize: 16384))
    }
}
