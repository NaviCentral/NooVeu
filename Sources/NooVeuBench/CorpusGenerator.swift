import CoreGraphics
import CoreText
import Foundation
import ImageIO
import NooVeuCore

struct CorpusEntry: Codable {
    /// Path relative to the corpus folder.
    var file: String
    var typeIdentifier: String
    /// Groups files for targets: `jpeg-24mp`, `orientation`, `malformed`, …
    var category: String
    /// Expected size after orientation; zero for malformed files.
    var pixelWidth: Int
    var pixelHeight: Int
    var orientation: Int
    var malformed: Bool
}

struct CorpusManifest: Codable {
    var generatedAt: String
    var macOS: String
    var entries: [CorpusEntry]
    /// Formats or variants this Mac could not write, with the reason.
    var skipped: [String]
}

/// Builds a synthetic, deterministic test corpus.
///
/// Every file is generated, so the corpus needs no downloads and carries no licence
/// questions. Real camera RAW samples have to be added by hand (see README).
enum CorpusGenerator {
    static let small = PixelSize(width: 1600, height: 1200)
    static let large24 = PixelSize(width: 6000, height: 4000)
    static let large100 = PixelSize(width: 12240, height: 8160)

    private struct Format {
        let typeIdentifier: String
        let fileExtension: String
        /// Some containers only hold specific sizes.
        var size: PixelSize = CorpusGenerator.small
    }

    private static let formats: [Format] = [
        Format(typeIdentifier: "public.jpeg", fileExtension: "jpg"),
        Format(typeIdentifier: "public.png", fileExtension: "png"),
        Format(typeIdentifier: "public.tiff", fileExtension: "tif"),
        Format(typeIdentifier: "com.compuserve.gif", fileExtension: "gif"),
        Format(typeIdentifier: "com.microsoft.bmp", fileExtension: "bmp"),
        Format(typeIdentifier: "public.heic", fileExtension: "heic"),
        Format(typeIdentifier: "public.avif", fileExtension: "avif"),
        Format(typeIdentifier: "public.jpeg-2000", fileExtension: "jp2"),
        Format(typeIdentifier: "com.ilm.openexr-image", fileExtension: "exr"),
        Format(typeIdentifier: "com.adobe.photoshop-image", fileExtension: "psd"),
        Format(typeIdentifier: "com.truevision.tga-image", fileExtension: "tga"),
        Format(typeIdentifier: "public.pbm", fileExtension: "pbm"),
        Format(typeIdentifier: "com.microsoft.ico", fileExtension: "ico", size: PixelSize(width: 256, height: 256)),
        Format(typeIdentifier: "com.apple.icns", fileExtension: "icns", size: PixelSize(width: 512, height: 512)),
        Format(typeIdentifier: "org.khronos.ktx", fileExtension: "ktx", size: PixelSize(width: 512, height: 512)),
        Format(typeIdentifier: "org.khronos.ktx2", fileExtension: "ktx2", size: PixelSize(width: 512, height: 512)),
        Format(typeIdentifier: "org.khronos.astc", fileExtension: "astc", size: PixelSize(width: 512, height: 512)),
        Format(typeIdentifier: "com.microsoft.dds", fileExtension: "dds", size: PixelSize(width: 512, height: 512)),
        Format(typeIdentifier: "public.pvr", fileExtension: "pvr", size: PixelSize(width: 512, height: 512)),
    ]

    static func generate(into root: URL, quick: Bool, log: (String) -> Void) throws -> CorpusManifest {
        let fm = FileManager.default
        for folder in ["formats", "large", "orientation", "variants", "malformed"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        var entries: [CorpusEntry] = []
        var skipped: [String] = []
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

        func add(_ image: CGImage, _ relative: String, type: String, category: String,
                 expected: PixelSize, orientation: Int = 1, properties: [CFString: Any] = [:]) {
            let url = root.appendingPathComponent(relative)
            guard FormatRegistry.writableTypes.contains(type) else {
                skipped.append("\(relative): ImageIO cannot write \(type) on this Mac")
                return
            }
            guard write(image, to: url, type: type, properties: properties) else {
                skipped.append("\(relative): ImageIO failed to write \(type)")
                return
            }
            guard ImageDecoder.probe(url) != nil else {
                skipped.append("\(relative): written but ImageIO cannot read it back")
                try? fm.removeItem(at: url)
                return
            }
            entries.append(CorpusEntry(file: relative, typeIdentifier: type, category: category,
                                       pixelWidth: expected.width, pixelHeight: expected.height,
                                       orientation: orientation, malformed: false))
            log("  \(relative)")
        }

        log("Formats at \(small)")
        for format in formats {
            let image = makeImage(format.size, label: format.fileExtension.uppercased(), colorSpace: sRGB)
            add(image, "formats/sample.\(format.fileExtension)", type: format.typeIdentifier,
                category: "format", expected: format.size, properties: quality(format.typeIdentifier))
        }

        log("Large files")
        var large: [(PixelSize, String, String, String)] = [
            (large24, "jpeg-24mp", "public.jpeg", "jpg"),
            (large24, "heic-24mp", "public.heic", "heic"),
        ]
        if !quick {
            large += [
                (large24, "png-24mp", "public.png", "png"),
                (large24, "avif-24mp", "public.avif", "avif"),
                (large100, "jpeg-100mp", "public.jpeg", "jpg"),
                (large100, "heic-100mp", "public.heic", "heic"),
            ]
        }
        for (size, category, type, ext) in large {
            let image = makeImage(size, label: "\(category.uppercased())  \(size)", colorSpace: sRGB)
            add(image, "large/\(category).\(ext)", type: type, category: category,
                expected: size, properties: quality(type))
        }

        log("EXIF orientations 1–8")
        let oriented = makeImage(small, label: "ORIENTATION", colorSpace: sRGB)
        for orientation in 1...8 {
            let expected = orientation >= 5 ? PixelSize(width: small.height, height: small.width) : small
            add(oriented, "orientation/orientation-\(orientation).jpg", type: "public.jpeg",
                category: "orientation", expected: expected, orientation: orientation,
                properties: [kCGImagePropertyOrientation: orientation,
                             kCGImageDestinationLossyCompressionQuality: 0.85])
        }

        log("Colour and alpha variants")
        if let p3 = CGColorSpace(name: CGColorSpace.displayP3) {
            add(makeImage(small, label: "DISPLAY P3", colorSpace: p3), "variants/display-p3.jpg",
                type: "public.jpeg", category: "variant", expected: small, properties: quality("public.jpeg"))
        }
        let base = makeImage(small, label: "VARIANT", colorSpace: sRGB)
        if let gray = redraw(base, colorSpace: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                             bitsPerComponent: 8, bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            add(gray, "variants/grayscale.png", type: "public.png", category: "variant", expected: small)
        } else { skipped.append("variants/grayscale.png: could not make a greyscale bitmap") }
        if let deep = redraw(base, colorSpace: sRGB, bitsPerComponent: 16,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) {
            add(deep, "variants/16-bit.png", type: "public.png", category: "variant", expected: small)
        } else { skipped.append("variants/16-bit.png: could not make a 16-bit bitmap") }
        if let cmyk = redraw(base, colorSpace: CGColorSpace(name: CGColorSpace.genericCMYK)!,
                             bitsPerComponent: 8, bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            add(cmyk, "variants/cmyk.jpg", type: "public.jpeg", category: "variant", expected: small,
                properties: quality("public.jpeg"))
        } else { skipped.append("variants/cmyk.jpg: could not make a CMYK bitmap") }
        add(makeImage(small, label: "ALPHA", colorSpace: sRGB, alphaHole: true), "variants/alpha.png",
            type: "public.png", category: "variant", expected: small)

        if writeAnimatedGIF(to: root.appendingPathComponent("variants/animated.gif")) {
            entries.append(CorpusEntry(file: "variants/animated.gif", typeIdentifier: "com.compuserve.gif",
                                       category: "variant", pixelWidth: 640, pixelHeight: 480,
                                       orientation: 1, malformed: false))
            log("  variants/animated.gif")
        } else { skipped.append("variants/animated.gif: write failed") }
        if writeMultipageTIFF(to: root.appendingPathComponent("variants/multipage.tif")) {
            entries.append(CorpusEntry(file: "variants/multipage.tif", typeIdentifier: "public.tiff",
                                       category: "variant", pixelWidth: small.width, pixelHeight: small.height,
                                       orientation: 1, malformed: false))
            log("  variants/multipage.tif")
        } else { skipped.append("variants/multipage.tif: write failed") }

        log("Malformed files")
        entries += try writeMalformed(from: entries, root: root)
        log("  \(entries.filter(\.malformed).count) files")

        return CorpusManifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            entries: entries,
            skipped: skipped
        )
    }

    // MARK: Pixels

    /// A deterministic test card: a gradient, fine rings that show resampling quality, colour
    /// patches, a white triangle marking the top-left corner (to check orientation), a label,
    /// and light noise so files compress like photographs rather than flat graphics.
    static func makeImage(_ size: PixelSize, label: String, colorSpace: CGColorSpace, alphaHole: Bool = false) -> CGImage {
        let width = size.width, height = size.height
        let alpha = alphaHole ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: colorSpace, bitmapInfo: alpha.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)

        let gradient = CGGradient(colorsSpace: colorSpace, colors: [
            CGColor(srgbRed: 0.10, green: 0.35, blue: 0.65, alpha: 1),
            CGColor(srgbRed: 0.95, green: 0.55, blue: 0.20, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])

        context.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        context.setLineWidth(max(1, w / 1600))
        let ringCenter = CGPoint(x: w * 0.7, y: h * 0.5)
        for ring in 1...60 {
            let radius = CGFloat(ring) * min(w, h) / 150
            context.strokeEllipse(in: CGRect(x: ringCenter.x - radius, y: ringCenter.y - radius,
                                             width: radius * 2, height: radius * 2))
        }

        let patch = min(w, h) / 16
        let hues: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (0, 1, 1), (1, 0, 1), (1, 1, 1), (0, 0, 0)]
        for (index, hue) in hues.enumerated() {
            context.setFillColor(CGColor(srgbRed: hue.0, green: hue.1, blue: hue.2, alpha: 1))
            context.fill(CGRect(x: w * 0.05 + CGFloat(index) * patch * 1.1, y: h * 0.2, width: patch, height: patch))
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.beginPath()
        context.move(to: CGPoint(x: 0, y: h))
        context.addLine(to: CGPoint(x: w * 0.12, y: h))
        context.addLine(to: CGPoint(x: 0, y: h - w * 0.12))
        context.closePath()
        context.fillPath()

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(10, h / 14), nil)
        let text = NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        context.textPosition = CGPoint(x: w * 0.05, y: h * 0.06)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)

        if alphaHole {
            context.setBlendMode(.clear)
            context.fillEllipse(in: CGRect(x: w * 0.35, y: h * 0.3, width: w * 0.3, height: h * 0.4))
            context.setBlendMode(.normal)
        }

        addNoise(to: context, width: width, height: height)
        return context.makeImage()!
    }

    private static func addNoise(to context: CGContext, width: Int, height: Int) {
        guard let data = context.data else { return }
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for row in 0..<height {
            let rowStart = row * context.bytesPerRow
            for column in 0..<width {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                let noise = Int(state & 7) - 4
                let pixel = rowStart + column * 4
                for channel in 0..<3 {
                    bytes[pixel + channel] = UInt8(clamping: Int(bytes[pixel + channel]) + noise)
                }
            }
        }
    }

    private static func redraw(_ image: CGImage, colorSpace: CGColorSpace, bitsPerComponent: Int, bitmapInfo: UInt32) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    // MARK: Files

    private static func quality(_ type: String) -> [CFString: Any] {
        ["public.jpeg", "public.heic", "public.avif", "public.jpeg-2000"].contains(type)
            ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
    }

    static func write(_ image: CGImage, to url: URL, type: String, properties: [CFString: Any]) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private static func writeAnimatedGIF(to url: URL) -> Bool {
        let frames = 12
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames, nil) else { return false }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        for frame in 0..<frames {
            let image = makeImage(PixelSize(width: 640, height: 480), label: "FRAME \(frame + 1)", colorSpace: sRGB)
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08],
            ] as CFDictionary)
        }
        return CGImageDestinationFinalize(destination)
    }

    private static func writeMultipageTIFF(to url: URL) -> Bool {
        let pages = 3
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, pages, nil) else { return false }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        for page in 0..<pages {
            CGImageDestinationAddImage(destination, makeImage(small, label: "PAGE \(page + 1)", colorSpace: sRGB), nil)
        }
        return CGImageDestinationFinalize(destination)
    }

    /// Damaged copies of real files: cut in half, cut to 100 bytes, and with a scrambled
    /// header; plus an empty file and a text file named like an image.
    private static func writeMalformed(from entries: [CorpusEntry], root: URL) throws -> [CorpusEntry] {
        let sources = ["formats/sample.jpg", "formats/sample.png", "formats/sample.heic", "formats/sample.avif",
                       "formats/sample.tif", "formats/sample.gif", "formats/sample.psd", "formats/sample.exr",
                       "formats/sample.jp2", "formats/sample.bmp"]
        var malformed: [CorpusEntry] = []

        func record(_ name: String, _ data: Data, type: String) throws {
            let relative = "malformed/\(name)"
            try data.write(to: root.appendingPathComponent(relative))
            malformed.append(CorpusEntry(file: relative, typeIdentifier: type, category: "malformed",
                                         pixelWidth: 0, pixelHeight: 0, orientation: 1, malformed: true))
        }

        for source in sources {
            guard let entry = entries.first(where: { $0.file == source }) else { continue }
            let data = try Data(contentsOf: root.appendingPathComponent(source))
            let ext = (source as NSString).pathExtension
            try record("truncated-half.\(ext)", data.prefix(data.count / 2), type: entry.typeIdentifier)
            try record("truncated-100-bytes.\(ext)", data.prefix(100), type: entry.typeIdentifier)
            var scrambled = data
            for index in 8..<min(400, scrambled.count) {
                scrambled[index] = scrambled[index] ^ 0xA5
            }
            try record("scrambled-header.\(ext)", scrambled, type: entry.typeIdentifier)
        }
        try record("empty.jpg", Data(), type: "public.jpeg")
        try record("text-named-jpg.jpg", Data("This is not an image.\n".utf8), type: "public.jpeg")
        return malformed
    }
}
