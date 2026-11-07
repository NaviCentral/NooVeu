import CoreGraphics
import Metal
import Testing
@testable import NooVeuRender

/// Renders real textures through the same code the app draws with and checks the pixels.
@Suite("Rendering", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct RenderTests {
    private let top = (r: 220, g: 40, b: 40)       // red above
    private let bottom = (r: 40, g: 40, b: 220)    // blue below

    /// An image whose top half is red and whose bottom half is blue.
    private func halves(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        func fill(_ c: (r: Int, g: Int, b: Int), y: Int) {
            context.setFillColor(CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: width, height: height / 2))
        }
        fill(top, y: height / 2)     // Core Graphics' y axis points up
        fill(bottom, y: 0)
        return context.makeImage()!
    }

    /// An image of alternating black and white columns, white first.
    private func stripes(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        for column in 0..<width {
            context.setFillColor(CGColor(gray: column % 2 == 0 ? 1 : 0, alpha: 1))
            context.fill(CGRect(x: column, y: 0, width: 1, height: height))
        }
        return context.makeImage()!
    }

    private func render(_ image: CGImage, transform: ViewTransform) async throws -> (bytes: [UInt8], frame: ImageRenderer.Frame) {
        let device = MTLCreateSystemDefaultDevice()!
        let factory = try #require(TextureFactory(device: device))
        let renderer = try #require(ImageRenderer(device: device))
        let prepared = try await factory.makeTexture(from: image)
        let frame = try renderer.renderOffscreen(texture: prepared.texture, transform: transform)
        return (frame.bytes(), frame)
    }

    private func near(_ pixel: (b: UInt8, g: UInt8, r: UInt8, a: UInt8), _ c: (r: Int, g: Int, b: Int), tolerance: Int = 3) -> Bool {
        abs(Int(pixel.r) - c.r) <= tolerance && abs(Int(pixel.g) - c.g) <= tolerance && abs(Int(pixel.b) - c.b) <= tolerance
    }

    @Test func topOfTheImageIsDrawnAtTheTopOfTheView() async throws {
        // 64×64 image centred in a 128×128 view: it occupies x 32…96 and y 32…96 from the top.
        let transform = ViewTransform(imageSize: CGSize(width: 64, height: 64),
                                      viewSize: CGSize(width: 128, height: 128), backingScale: 1)

        let (bytes, frame) = try await render(halves(64, 64), transform: transform)

        #expect(near(frame.pixel(x: 64, y: 40, in: bytes), top), "red half at the top")
        #expect(near(frame.pixel(x: 64, y: 88, in: bytes), bottom), "blue half at the bottom")
        #expect(near(frame.pixel(x: 5, y: 5, in: bytes), (0, 0, 0)), "outside the image is the clear colour")
        #expect(near(frame.pixel(x: 122, y: 122, in: bytes), (0, 0, 0)))
    }

    @Test func aDownsampledTextureIsDrawnAtTheSourceSize() async throws {
        // A 16×16 texture standing in for a 64×64 source covers the same footprint.
        let transform = ViewTransform(imageSize: CGSize(width: 64, height: 64),
                                      viewSize: CGSize(width: 128, height: 128), backingScale: 1)

        let (bytes, frame) = try await render(halves(16, 16), transform: transform)

        #expect(near(frame.pixel(x: 64, y: 40, in: bytes), top))
        #expect(near(frame.pixel(x: 64, y: 88, in: bytes), bottom))
        #expect(near(frame.pixel(x: 20, y: 64, in: bytes), (0, 0, 0)), "left of the footprint is empty")
    }

    @Test func actualPixelsOfAnOddSizedImageAreSharp() async throws {
        // 101 columns in a 150-pixel view would sit on a half pixel and blur every column to
        // grey without the device-pixel snap.
        var transform = ViewTransform(imageSize: CGSize(width: 101, height: 4),
                                      viewSize: CGSize(width: 150, height: 10), backingScale: 1)
        transform.setZoom(1)
        let left = Int(transform.imageRectInView.minX)

        let (bytes, frame) = try await render(stripes(101, 4), transform: transform)

        for column in 0..<101 {
            let pixel = frame.pixel(x: left + column, y: 5, in: bytes)
            let expected = column % 2 == 0 ? 255 : 0
            #expect(abs(Int(pixel.r) - expected) <= 2, "column \(column): \(pixel.r)")
        }
    }

    /// An image of alternating black and white rows, white first.
    private func rowStripes(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        for row in 0..<height {
            context.setFillColor(CGColor(gray: row % 2 == 0 ? 1 : 0, alpha: 1))
            // Core Graphics counts rows from the bottom; row 0 is the top of the picture.
            context.fill(CGRect(x: 0, y: height - 1 - row, width: width, height: 1))
        }
        return context.makeImage()!
    }

    @Test(arguments: [1, 2])
    func actualPixelsOfAnOddHeightImageAreSharpVertically(scale: Int) async throws {
        // 101 rows in a 150-pixel-tall view: half a pixel off without the vertical snap.
        let points = CGFloat(150) / CGFloat(scale)
        var transform = ViewTransform(imageSize: CGSize(width: 4, height: 101),
                                      viewSize: CGSize(width: 10 / CGFloat(scale), height: points), backingScale: CGFloat(scale))
        transform.setZoom(1)
        let top = Int((transform.viewSize.height - transform.imageRectInView.maxY) * CGFloat(scale))

        let (bytes, frame) = try await render(rowStripes(4, 101), transform: transform)

        for row in 0..<101 {
            let pixel = frame.pixel(x: 5, y: top + row, in: bytes)
            let expected = row % 2 == 0 ? 255 : 0
            #expect(abs(Int(pixel.r) - expected) <= 2, "scale \(scale), row \(row): \(pixel.r)")
        }
    }

    @Test(arguments: [true, false])
    func aFractionallyPannedImageStaysSharpAtActualPixels(vertical: Bool) async throws {
        // A pan by 0.3 of a pixel puts the image's edge between device pixels. The snap must move
        // it to a whole pixel in the right direction: the wrong direction lands 0.6 of a pixel
        // off, which blurs every row (or column). A tie at exactly half a pixel could not tell the
        // two apart, which is why this pans by a fraction.
        let image = vertical ? rowStripes(4, 301) : stripes(301, 4)
        var transform = ViewTransform(
            imageSize: CGSize(width: vertical ? 4 : 301, height: vertical ? 301 : 4),
            viewSize: CGSize(width: vertical ? 10 : 150, height: vertical ? 150 : 10), backingScale: 1)
        transform.setZoom(1)
        transform.pan(by: CGSize(width: 0.3, height: 0.3))

        let (bytes, frame) = try await render(image, transform: transform)

        // Every visible pixel is pure black or pure white: nothing in between.
        let length = vertical ? 150 : 150
        for offset in 0..<length {
            let pixel = vertical ? frame.pixel(x: 5, y: offset, in: bytes) : frame.pixel(x: offset, y: 5, in: bytes)
            #expect(pixel.r >= 253 || pixel.r <= 2, "\(vertical ? "row" : "column") \(offset): \(pixel.r)")
        }
    }

    @Test func aTwoTimesDisplayDrawsAtDevicePixels() async throws {
        // 64×64 image, 2× display, 100% zoom: 64 device pixels, 32 points.
        var transform = ViewTransform(imageSize: CGSize(width: 64, height: 64),
                                      viewSize: CGSize(width: 64, height: 64), backingScale: 2)
        transform.setZoom(1)

        let (bytes, frame) = try await render(halves(64, 64), transform: transform)

        #expect(frame.width == 128 && frame.height == 128)
        // The image covers device pixels 32…95 in both directions; its first and last rows count.
        #expect(near(frame.pixel(x: 64, y: 32, in: bytes), top), "first row")
        #expect(near(frame.pixel(x: 64, y: 95, in: bytes), bottom), "last row")
        #expect(near(frame.pixel(x: 64, y: 31, in: bytes), (0, 0, 0)), "just above the image")
        #expect(near(frame.pixel(x: 64, y: 96, in: bytes), (0, 0, 0)), "just below the image")
    }

    @Test func aFrameReportsGPUTime() async throws {
        let transform = ViewTransform(imageSize: CGSize(width: 64, height: 64),
                                      viewSize: CGSize(width: 128, height: 128), backingScale: 1)

        let (_, frame) = try await render(halves(64, 64), transform: transform)

        #expect(frame.gpuSeconds > 0 && frame.gpuSeconds < 1)
    }
}
