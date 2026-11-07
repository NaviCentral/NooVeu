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
