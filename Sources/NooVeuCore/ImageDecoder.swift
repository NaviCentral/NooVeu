import CoreGraphics
import Foundation
import ImageIO

public enum DecodeError: Error, Equatable, Sendable {
    /// ImageIO could not open the file or did not recognise its format.
    case unreadable(URL)
    /// The file opened but holds no image.
    case empty(URL)
    /// ImageIO recognised the file but failed while decoding its pixels.
    case decodeFailed(URL)
}

public struct DecodeOptions: Hashable, Sendable {
    /// The longest side the caller needs, in pixels; `nil` means full resolution.
    ///
    /// This is a hint, not an exact size: the decoder may return a somewhat larger or
    /// slightly smaller bitmap when that is much faster (see `DecodeStrategy`), and the GPU
    /// scales it to the screen.
    public var maxPixelSize: Int?

    public init(maxPixelSize: Int? = nil) {
        // Zero or negative sizes mean "as small as possible", never "unlimited".
        self.maxPixelSize = maxPixelSize.map { max($0, 1) }
    }

    public static let fullResolution = DecodeOptions()

    public static func fitting(_ longestSide: Int) -> DecodeOptions {
        DecodeOptions(maxPixelSize: longestSide)
    }
}

/// What ImageIO reports about a file without decoding its pixels.
public struct ImageProbe: Sendable, Equatable {
    public let typeIdentifier: String?
    /// Size after EXIF orientation is applied.
    public let orientedSize: PixelSize
    public let orientation: CGImagePropertyOrientation
    public let frameCount: Int
}

/// How a file is turned into pixels. Chosen per format from phase 0 measurements on an
/// M4 Pro (24 MP source, screen-sized result):
///
/// | Format      | Fastest path                        | Measured |
/// |-------------|-------------------------------------|----------|
/// | JPEG        | ImageIO subsampling (DCT scaling)   | 25 ms at 1/2, vs 114 ms via the thumbnail API |
/// | HEIC, AVIF  | ImageIO thumbnail API               | 67 / 49 ms, vs 81 / 97 ms subsampled |
/// | PNG, others | Full decode; the GPU scales it      | PNG 191 ms full, 235 ms via the thumbnail API |
public enum DecodeStrategy: Equatable, Sendable {
    /// Decode at 1/`factor` of full size (1 = full size), then orient and copy into a
    /// GPU-ready bitmap.
    case subsample(factor: Int)
    /// Let ImageIO decode, scale and orient to fit `maxPixelSize` in one pass.
    case thumbnail(maxPixelSize: Int)

    private static let subsampledTypes: Set<String> = ["public.jpeg"]
    private static let thumbnailTypes: Set<String> = ["public.heic", "public.heif", "public.avif", "public.avci"]

    /// - Parameters:
    ///   - typeIdentifier: The source's uniform type identifier.
    ///   - sourceLongestSide: The source's longest side in pixels.
    ///   - target: The longest side needed, already capped to the largest texture.
    public static func choose(typeIdentifier: String?, sourceLongestSide: Int, target: Int) -> DecodeStrategy {
        guard sourceLongestSide > target else { return .subsample(factor: 1) }
        let type = typeIdentifier ?? ""

        if subsampledTypes.contains(type) {
            // A first view may be up to a quarter smaller than the target: it is replaced by
            // full detail as soon as the user zooms in.
            for factor in [8, 4, 2] where sourceLongestSide / factor >= target * 3 / 4 {
                if sourceLongestSide / factor <= ImageDecoder.maxTextureDimension {
                    return .subsample(factor: factor)
                }
            }
        }
        if thumbnailTypes.contains(type) || sourceLongestSide > ImageDecoder.maxTextureDimension {
            return .thumbnail(maxPixelSize: target)
        }
        return .subsample(factor: 1)
    }
}

/// Decodes image files with Apple's ImageIO (tier 1 formats).
///
/// Every bitmap returned is fully decoded into memory, on the calling thread. ImageIO
/// otherwise decodes lazily, on first access to the pixels, which would move the work onto
/// whichever thread first draws the image: the main thread, at texture upload.
///
/// All functions are synchronous and can take hundreds of milliseconds on large files:
/// call them through `DecodeScheduler`, never on the main thread.
public enum ImageDecoder {
    /// Largest texture side Metal supports on Apple Silicon GPUs.
    /// Larger images are downsampled to this until tiled rendering lands in phase 1.
    public static let maxTextureDimension = 16_384

    public static func probe(_ url: URL) -> ImageProbe? {
        guard let source = makeSource(url), CGImageSourceGetCount(source) > 0,
              let info = SourceInfo(source) else { return nil }
        return ImageProbe(
            typeIdentifier: CGImageSourceGetType(source) as String?,
            orientedSize: info.orientedSize,
            orientation: info.orientation,
            frameCount: CGImageSourceGetCount(source)
        )
    }

    /// Decodes the first frame of `url` with its EXIF orientation applied.
    /// - Throws: `DecodeError`.
    public static func decode(_ url: URL, options: DecodeOptions = .fullResolution) throws -> DecodedImage {
        let clock = ContinuousClock()
        let start = clock.now

        guard let source = makeSource(url), let type = CGImageSourceGetType(source) as String? else {
            throw DecodeError.unreadable(url)
        }
        guard CGImageSourceGetCount(source) > 0 else { throw DecodeError.empty(url) }
        guard let info = SourceInfo(source) else { throw DecodeError.decodeFailed(url) }

        let target = min(options.maxPixelSize ?? Int.max, maxTextureDimension)
        let strategy = DecodeStrategy.choose(typeIdentifier: type,
                                             sourceLongestSide: info.orientedSize.longestSide,
                                             target: target)
        var image: CGImage?
        switch strategy {
        case .subsample(let factor):
            image = decodeSubsampled(source, factor: factor, orientation: info.orientation)
        case .thumbnail(let maxPixelSize):
            // The thumbnail API returns decoded pixels with orientation applied.
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary)
            // Some files refuse to scale (for instance a tiny `maxPixelSize`): show them whole.
            if image == nil, info.orientedSize.longestSide <= maxTextureDimension {
                image = decodeSubsampled(source, factor: 1, orientation: info.orientation)
            }
        }
        guard let image else { throw DecodeError.decodeFailed(url) }

        return DecodedImage(
            cgImage: image,
            sourcePixelSize: info.orientedSize,
            typeIdentifier: type,
            decodeDuration: clock.now - start
        )
    }

    /// A small preview for thumbnail grids. Uses the file's embedded thumbnail when it has
    /// one, and decodes (with fast subsampling where the format allows) when it does not.
    /// - Throws: `DecodeError`.
    public static func thumbnail(_ url: URL, maxPixelSize: Int) throws -> DecodedImage {
        let clock = ContinuousClock()
        let start = clock.now

        guard let source = makeSource(url), CGImageSourceGetType(source) != nil else {
            throw DecodeError.unreadable(url)
        }
        guard CGImageSourceGetCount(source) > 0 else { throw DecodeError.empty(url) }
        let info = SourceInfo(source)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary) else { throw DecodeError.decodeFailed(url) }

        return DecodedImage(
            cgImage: image,
            sourcePixelSize: info?.orientedSize ?? PixelSize(width: image.width, height: image.height),
            typeIdentifier: CGImageSourceGetType(source) as String?,
            decodeDuration: clock.now - start
        )
    }

    /// Decodes the first frame (optionally at 1/`factor` size) and copies it, oriented, into a
    /// GPU-ready bitmap.
    ///
    /// The copy is what forces the decode to finish here, on a background thread. It is never
    /// skipped, even for an upright JPEG: once the file's properties have been read, ImageIO
    /// returns even a `ShouldCacheImmediately` image undecoded, and the work would then land on
    /// the main thread at texture upload (measured: 60 ms for a 24 MP JPEG, 150 ms for a PNG).
    private static func decodeSubsampled(
        _ source: CGImageSource, factor: Int, orientation: CGImagePropertyOrientation
    ) -> CGImage? {
        var imageOptions: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        if factor > 1 { imageOptions[kCGImageSourceSubsampleFactor] = factor }
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, imageOptions as CFDictionary) else { return nil }
        return materialize(decoded, orientation: orientation)
    }

    /// Forces a full decode by drawing into an 8-bit BGRA bitmap (the layout Metal uploads
    /// without conversion), applying the EXIF orientation on the way.
    ///
    /// RGB images keep their colour space; greyscale, CMYK and indexed images are converted to
    /// Display P3. Deeper-than-8-bit and HDR sources lose precision here: phase 1 adds a
    /// half-float path for them.
    static func materialize(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
        let width = image.width, height = image.height
        let swapsAxes: Bool
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: swapsAxes = true
        default: swapsAxes = false
        }
        let outputWidth = swapsAxes ? height : width
        let outputHeight = swapsAxes ? width : height
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        let preferred = image.colorSpace?.model == .rgb ? image.colorSpace : nil
        let context = preferred.flatMap {
            CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8,
                      bytesPerRow: 0, space: $0, bitmapInfo: bitmapInfo)
        } ?? CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8,
                       bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: bitmapInfo)
        guard let context else { return nil }

        context.interpolationQuality = .none
        context.concatenate(orientationTransform(orientation, width: CGFloat(width), height: CGFloat(height)))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Maps the stored picture (`width` × `height`, drawn upright at the origin in Core
    /// Graphics' y-up space) onto the displayed one. Derived from the EXIF definitions:
    /// 2 mirror, 3 rotate 180°, 4 flip, 5 transpose, 6 rotate 90° clockwise, 7 transverse,
    /// 8 rotate 90° anticlockwise.
    static func orientationTransform(_ orientation: CGImagePropertyOrientation, width w: CGFloat, height h: CGFloat) -> CGAffineTransform {
        switch orientation {
        case .up: return .identity
        case .upMirrored: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        @unknown default: return .identity
        }
    }

    private static func makeSource(_ url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}

/// Size and orientation of a source's first frame.
struct SourceInfo {
    let orientation: CGImagePropertyOrientation
    let orientedSize: PixelSize

    init?(_ source: CGImageSource) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }

        let raw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            orientedSize = PixelSize(width: height, height: width)
        default:
            orientedSize = PixelSize(width: width, height: height)
        }
    }
}
