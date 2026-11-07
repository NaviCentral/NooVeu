import CoreGraphics
import Metal
import NooVeuCore

public enum RenderError: Error, Sendable {
    case commandBufferUnavailable
    case targetUnavailable
    case failed(String)
}

/// Draws an image texture as one textured quad.
///
/// The on-screen canvas and the offscreen test and benchmark paths share this, so what the
/// tests render is what the user sees.
@MainActor
public final class ImageRenderer {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let pixelFormat: MTLPixelFormat
    private let pipeline: MTLRenderPipelineState
    private let library: MTLLibrary
    /// Built the first time tiles are drawn: most images never need it.
    private lazy var tilePipeline: MTLRenderPipelineState? = try? Shaders.makePipeline(library: library, pixelFormat: pixelFormat, tiles: true)
    private let smoothSampler: MTLSamplerState
    private let pixelSampler: MTLSamplerState

    /// Fails only when Metal is unavailable, which no Apple Silicon Mac lacks.
    public init?(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = try? Shaders.makeLibrary(device: device),
              let pipeline = try? Shaders.makePipeline(library: library, pixelFormat: pixelFormat),
              let smooth = Shaders.makeSampler(device: device, pixelGrid: false),
              let pixel = Shaders.makeSampler(device: device, pixelGrid: true)
        else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.pixelFormat = pixelFormat
        self.pipeline = pipeline
        self.library = library
        self.smoothSampler = smooth
        self.pixelSampler = pixel
    }

    /// Encodes the draw call for `texture` placed by `transform`.
    public func encode(into encoder: MTLRenderCommandEncoder, texture: MTLTexture, transform: ViewTransform) {
        var rect = transform.clipRect
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(transform.showsPixelGrid ? pixelSampler : smoothSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Encodes tiles in the order given (later ones draw over earlier ones), each placed by its own
    /// clip rectangle. Call after `encode` for a base texture, coarser tiles first.
    public func encode(into encoder: MTLRenderCommandEncoder, tiles: [TileQuad], showsPixelGrid: Bool) {
        guard !tiles.isEmpty, let tilePipeline else { return }
        encoder.setRenderPipelineState(tilePipeline)
        encoder.setFragmentSamplerState(showsPixelGrid ? pixelSampler : smoothSampler, index: 0)
        for tile in tiles {
            var rect = tile.clipRect, uv = tile.uvRect
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setVertexBytes(&uv, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.setFragmentTexture(tile.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// One rendered frame: its pixels, and how long the GPU spent on it.
    public struct Frame {
        public let texture: MTLTexture
        /// Time the GPU spent executing the frame, from the command buffer's own timestamps.
        public let gpuSeconds: Double
        public let width: Int
        public let height: Int

        /// The frame's pixels, one row after another, top row first, in the renderer's pixel
        /// format (four bytes per pixel).
        public func bytes() -> [UInt8] {
            let rowBytes = width * 4
            var data = [UInt8](repeating: 0, count: rowBytes * height)
            data.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: rowBytes,
                                 from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            return data
        }

        /// The pixel at (`x`, `y`), counted from the top left, as blue, green, red, alpha.
        public func pixel(x: Int, y: Int, in bytes: [UInt8]) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let offset = (y * width + x) * 4
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }
    }

    /// Renders `texture` into a new offscreen target the size of the transform's view in device
    /// pixels, and waits for the GPU to finish. Used by tests and the benchmark; the app draws
    /// to its window instead.
    public func renderOffscreen(texture: MTLTexture, transform: ViewTransform) throws -> Frame {
        try renderOffscreen(base: texture, tiles: [], transform: transform)
    }

    /// Renders an optional base texture and then tiles over it (see `encode(into:tiles:showsPixelGrid:)`).
    public func renderOffscreen(base: MTLTexture?, tiles: [TileQuad], transform: ViewTransform) throws -> Frame {
        let width = Int((transform.viewSize.width * transform.backingScale).rounded())
        let height = Int((transform.viewSize.height * transform.backingScale).rounded())
        guard width > 0, height > 0 else { throw RenderError.targetUnavailable }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else { throw RenderError.targetUnavailable }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { throw RenderError.commandBufferUnavailable }
        if let base { encode(into: encoder, texture: base, transform: transform) }
        encode(into: encoder, tiles: tiles, showsPixelGrid: transform.showsPixelGrid)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error { throw RenderError.failed(error.localizedDescription) }

        return Frame(texture: target, gpuSeconds: buffer.gpuEndTime - buffer.gpuStartTime,
                     width: width, height: height)
    }
}
