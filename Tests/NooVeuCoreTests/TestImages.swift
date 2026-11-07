import CoreGraphics
import Foundation
import ImageIO
@testable import NooVeuCore

/// Small images and temporary folders for tests.
enum TestImages {
    static func make(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @discardableResult
    static func write(width: Int, height: Int, to url: URL, type: String = "public.png",
                      properties: [CFString: Any] = [:]) -> URL {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, make(width: width, height: height), properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination), "could not write test image \(url.path)")
        return url
    }

    static func decoded(width: Int, height: Int) -> DecodedImage {
        DecodedImage(cgImage: make(width: width, height: height),
                     sourcePixelSize: PixelSize(width: width, height: height),
                     typeIdentifier: "public.png", decodeDuration: .zero)
    }
}

/// A temporary folder removed when the value is released.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NooVeuTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name, isDirectory: false)
    }

    func touch(_ name: String, contents: String = "") throws {
        try Data(contents.utf8).write(to: file(name))
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Four solid colours that are easy to tell apart even after lossy compression.
enum Quadrant: CaseIterable, CustomStringConvertible {
    case red, green, blue, yellow

    var rgb: (r: Int, g: Int, b: Int) {
        switch self {
        case .red: (220, 40, 40)
        case .green: (40, 200, 40)
        case .blue: (40, 40, 220)
        case .yellow: (230, 210, 40)
        }
    }

    var description: String {
        switch self {
        case .red: "red"
        case .green: "green"
        case .blue: "blue"
        case .yellow: "yellow"
        }
    }

    /// The colour in `Quadrant.allCases` nearest to a sampled pixel.
    static func nearest(r: Int, g: Int, b: Int) -> Quadrant {
        allCases.min { distance($0, r, g, b) < distance($1, r, g, b) }!
    }

    private static func distance(_ q: Quadrant, _ r: Int, _ g: Int, _ b: Int) -> Int {
        let c = q.rgb
        return (c.r - r) * (c.r - r) + (c.g - g) * (c.g - g) + (c.b - b) * (c.b - b)
    }
}

extension TestImages {
    /// A picture with red top-left, green top-right, blue bottom-left and yellow bottom-right.
    static func quadrants(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        func fill(_ quadrant: Quadrant, x: Int, yFromTop: Int) {
            let c = quadrant.rgb
            context.setFillColor(CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                                         blue: CGFloat(c.b) / 255, alpha: 1))
            // Core Graphics' y axis points up.
            context.fill(CGRect(x: x, y: height - height / 2 - yFromTop, width: width / 2, height: height / 2))
        }
        fill(.red, x: 0, yFromTop: 0)
        fill(.green, x: width / 2, yFromTop: 0)
        fill(.blue, x: 0, yFromTop: height / 2)
        fill(.yellow, x: width / 2, yFromTop: height / 2)
        return context.makeImage()!
    }

    @discardableResult
    static func writeQuadrants(width: Int, height: Int, to url: URL, type: String,
                               properties: [CFString: Any] = [:]) -> URL {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, quadrants(width: width, height: height), properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination), "could not write \(url.path)")
        return url
    }

    /// The colours at the centres of the four quarters of `image`: top-left, top-right,
    /// bottom-left, bottom-right.
    static func quarterColors(of image: CGImage) -> [Quadrant] {
        let width = image.width, height = image.height
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = context.data!.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        // Row 0 of the buffer is the top of the picture.
        return [(width / 4, height / 4), (3 * width / 4, height / 4),
                (width / 4, 3 * height / 4), (3 * width / 4, 3 * height / 4)].map { x, y in
            let offset = y * context.bytesPerRow + x * 4
            return Quadrant.nearest(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]))
        }
    }
}

extension TestImages {
    /// A picture where every pixel differs: red grows to the right, green downward, blue along the
    /// diagonal. Any tile cut from the wrong place shows at once.
    ///
    /// With `smooth`, blue also grows steadily instead of wrapping around, so there are no sharp colour
    /// edges: a better stand-in for a photograph when testing lossy formats.
    static func gradient(width: Int, height: Int, smooth: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let bytes = context.data!.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * context.bytesPerRow + x * 4
                bytes[offset] = UInt8(x * 255 / max(width - 1, 1))
                bytes[offset + 1] = UInt8(y * 255 / max(height - 1, 1))
                bytes[offset + 2] = smooth ? UInt8((x + y) * 255 / max(width + height - 2, 1)) : UInt8((x * 3 + y * 5) % 256)
                bytes[offset + 3] = 255
            }
        }
        return context.makeImage()!
    }

    @discardableResult
    static func writeGradient(width: Int, height: Int, smooth: Bool = false, to url: URL, type: String, properties: [CFString: Any] = [:]) -> URL {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, gradient(width: width, height: height, smooth: smooth), properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination), "could not write \(url.path)")
        return url
    }

    /// The pixels of `image` as sRGB RGBA bytes, rows top to bottom.
    static func rgba(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4),
                                         count: image.width * image.height * 4))
    }

    /// The largest difference in any channel between two images of the same size.
    static func maxDifference(_ a: CGImage, _ b: CGImage) -> Int {
        guard a.width == b.width, a.height == b.height else { return Int.max }
        let x = rgba(a), y = rgba(b)
        return zip(x, y).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }
}

extension TestImages {
    /// Deterministic noise: every pixel unrelated to its neighbours, which shows any seam or
    /// misplacement that a smooth picture would hide.
    static func noise(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
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

    static func grey(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
