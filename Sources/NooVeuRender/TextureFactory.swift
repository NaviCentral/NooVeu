import CoreGraphics
import Foundation
import Metal
import MetalKit
import NooVeuCore

public enum TextureError: Error, Sendable {
    case conversionFailed
}

/// A GPU texture ready to draw, with the colour space its values are encoded in.
public struct PreparedTexture: @unchecked Sendable {
    public let texture: MTLTexture
    public let colorSpace: CGColorSpace
    /// Time spent converting (if needed) and uploading.
    public let uploadDuration: Duration
}

/// Turns decoded bitmaps into mipmapped GPU textures, off the main thread.
///
/// 8-bit RGB images go up as they are and the layer is tagged with their colour space, so
/// macOS colour-manages them to the display. Everything else (greyscale, CMYK, indexed,
/// 16-bit) is first redrawn into 8-bit Display P3. Wide-gamut and HDR handling at full
/// precision is phase 1 work.
///
/// `MTKTextureLoader` is safe to call from any thread and `MTLDevice` is immutable here, so
/// the factory is shared freely.
public final class TextureFactory: @unchecked Sendable {
    public let device: MTLDevice
    private let loader: MTKTextureLoader

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device else { return nil }
        self.device = device
        self.loader = MTKTextureLoader(device: device)
    }

    /// Converts (when needed) and uploads `image`, including the GPU's mipmap generation, and
    /// returns when the texture is ready to draw. Runs on a background executor: the main
    /// thread is free while a 100 MP image goes up.
    @concurrent
    public func makeTexture(from image: CGImage) async throws -> PreparedTexture {
        let clock = ContinuousClock()
        let start = clock.now

        var source = image
        var colorSpace = image.colorSpace
        if !image.isMetalUploadable || colorSpace == nil {
            (source, colorSpace) = try Self.redrawAsDisplayP3(image)
        }

        let texture: MTLTexture
        do {
            texture = try await loader.newTexture(cgImage: source, options: Self.loaderOptions)
        } catch {
            // The loader rejects some pixel layouts; a redraw always yields one it accepts.
            (source, colorSpace) = try Self.redrawAsDisplayP3(image)
            texture = try await loader.newTexture(cgImage: source, options: Self.loaderOptions)
        }
        return PreparedTexture(texture: texture, colorSpace: colorSpace!, uploadDuration: clock.now - start)
    }

    nonisolated(unsafe) private static let loaderOptions: [MTKTextureLoader.Option: Any] = [
        .SRGB: false,
        .allocateMipmaps: true,
        .generateMipmaps: true,
        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
    ]

    private static func redrawAsDisplayP3(_ image: CGImage) throws -> (CGImage, CGColorSpace) {
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: p3,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { throw TextureError.conversionFailed }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let redrawn = context.makeImage() else { throw TextureError.conversionFailed }
        return (redrawn, p3)
    }
}
