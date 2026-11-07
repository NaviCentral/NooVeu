import CoreGraphics
import Foundation

/// Width and height in pixels.
public struct PixelSize: Hashable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var longestSide: Int { max(width, height) }
    public var megapixels: Double { Double(width) * Double(height) / 1_000_000 }
    public var description: String { "\(width)×\(height)" }
}

/// A decoded bitmap. From `ImageDecoder.decode` it is fully decoded and in a layout Metal uploads
/// directly; a thumbnail is a plain `CGImage` in whatever layout ImageIO produced.
///
/// `CGImage` is immutable, so a `DecodedImage` is safe to share between threads.
public struct DecodedImage: @unchecked Sendable {
    /// The bitmap, with EXIF orientation already applied.
    public let cgImage: CGImage
    /// Full-resolution size of the source after orientation, even when `cgImage` was downsampled.
    public let sourcePixelSize: PixelSize
    /// Uniform type identifier of the source file, such as `public.jpeg`.
    public let typeIdentifier: String?
    /// How long the decode took.
    public let decodeDuration: Duration

    public init(cgImage: CGImage, sourcePixelSize: PixelSize, typeIdentifier: String?, decodeDuration: Duration) {
        self.cgImage = cgImage
        self.sourcePixelSize = sourcePixelSize
        self.typeIdentifier = typeIdentifier
        self.decodeDuration = decodeDuration
    }

    public var pixelSize: PixelSize { PixelSize(width: cgImage.width, height: cgImage.height) }

    public var isDownsampled: Bool {
        pixelSize.width < sourcePixelSize.width || pixelSize.height < sourcePixelSize.height
    }

    /// Memory held by the bitmap, used for cache accounting.
    public var byteCost: Int { cgImage.bytesPerRow * cgImage.height }
}

extension Duration {
    /// The duration in milliseconds, for logs and reports.
    public var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}

extension CGImage {
    /// Whether Metal can take this bitmap as a texture without converting it: 8-bit RGB with
    /// four bytes per pixel, either BGRA (little-endian, alpha or padding first) or RGBA
    /// (alpha or padding last).
    public var isMetalUploadable: Bool {
        guard bitsPerComponent == 8, bitsPerPixel == 32, colorSpace?.model == .rgb else { return false }
        let order = bitmapInfo.intersection(.byteOrderMask)
        switch (order, alphaInfo) {
        case (.byteOrder32Little, .premultipliedFirst), (.byteOrder32Little, .noneSkipFirst):
            return true
        case (.byteOrderDefault, .premultipliedLast), (.byteOrderDefault, .noneSkipLast):
            return true
        default:
            return false
        }
    }
}
