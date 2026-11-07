// Draws NooVeu's placeholder app icon: a framed picture (sun over two hills) on a blue tile.
//
//   swift scripts/make-icon.swift <output.iconset>
//
// Writes every size macOS expects into the .iconset folder; `iconutil -c icns` turns that into
// AppIcon.icns (scripts/bundle-app.sh does both). The drawing is vector, so each size is drawn
// afresh rather than scaled. This is a stand-in until there is a real icon.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func gradient(_ top: CGColor, _ bottom: CGColor) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
}

/// Draws the icon into a square context `size` pixels across. Coordinates are in units of
/// `size`, with the origin at the bottom left.
func drawIcon(_ context: CGContext, size: CGFloat) {
    func u(_ value: CGFloat) -> CGFloat { value * size }
    func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    // The tile: macOS icons leave a margin around the artwork.
    let tile = CGRect(x: u(0.098), y: u(0.098), width: u(0.804), height: u(0.804))
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -u(0.012)), blur: u(0.03), color: color(0, 0, 0, 0.35))
    context.addPath(roundedRect(tile, radius: u(0.18)))
    context.setFillColor(color(0.10, 0.25, 0.48))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(roundedRect(tile, radius: u(0.18)))
    context.clip()
    context.drawLinearGradient(gradient(color(0.22, 0.47, 0.78), color(0.07, 0.16, 0.36)),
                               start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // The photo: a white frame with a sky, a sun and two hills.
    let frame = CGRect(x: u(0.22), y: u(0.29), width: u(0.56), height: u(0.42))
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -u(0.01)), blur: u(0.02), color: color(0, 0, 0, 0.3))
    context.addPath(roundedRect(frame, radius: u(0.03)))
    context.setFillColor(color(1, 1, 1))
    context.fillPath()
    context.restoreGState()

    let picture = frame.insetBy(dx: u(0.028), dy: u(0.028))
    context.saveGState()
    context.addPath(roundedRect(picture, radius: u(0.012)))
    context.clip()
    context.drawLinearGradient(gradient(color(0.55, 0.78, 0.97), color(0.86, 0.94, 1.0)),
                               start: CGPoint(x: 0, y: picture.maxY), end: CGPoint(x: 0, y: picture.minY), options: [])

    context.setFillColor(color(1.0, 0.82, 0.25))
    let sunRadius = u(0.05)
    context.fillEllipse(in: CGRect(x: picture.minX + u(0.34), y: picture.maxY - u(0.13) - sunRadius,
                                   width: sunRadius * 2, height: sunRadius * 2))

    func hill(_ points: [(CGFloat, CGFloat)], _ fill: CGColor) {
        context.beginPath()
        context.move(to: CGPoint(x: picture.minX + points[0].0 * picture.width, y: picture.minY + points[0].1 * picture.height))
        for point in points.dropFirst() {
            context.addLine(to: CGPoint(x: picture.minX + point.0 * picture.width, y: picture.minY + point.1 * picture.height))
        }
        context.closePath()
        context.setFillColor(fill)
        context.fillPath()
    }
    hill([(0, 0), (0, 0.38), (0.30, 0.62), (0.62, 0.20), (0.62, 0)], color(0.20, 0.45, 0.42))
    hill([(0.28, 0), (0.62, 0.52), (0.84, 0.30), (1, 0.42), (1, 0)], color(0.12, 0.30, 0.32))
    context.restoreGState()
    context.restoreGState()
}

func writePNG(size: Int, to url: URL) {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    drawIcon(context, size: CGFloat(size))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("error: could not write \(url.path)\n".utf8))
        exit(1)
    }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <output.iconset>\n".utf8))
    exit(64)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

// The names and pixel sizes `iconutil` expects.
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                       ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
                       ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    writePNG(size: pixels, to: folder.appendingPathComponent("\(name).png"))
}
