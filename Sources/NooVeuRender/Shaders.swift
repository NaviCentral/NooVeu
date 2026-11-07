import Metal

/// Shader source compiled at run time.
///
/// Phase 0 builds with the Command Line Tools, which lack the offline `metal` compiler.
/// Once the Xcode project exists this moves to a `.metal` file compiled at build time.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadOut {
        float4 position [[position]];
        float2 uv;
    };

    // Draws one textured quad covering `rect` (minX, minY, maxX, maxY in clip space).
    // Texture row 0 is the top of the image, so the top edge samples v = 0.
    vertex QuadOut quad_vertex(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        const float2 corners[4] = {
            float2(rect.x, rect.y), float2(rect.z, rect.y),
            float2(rect.x, rect.w), float2(rect.z, rect.w)
        };
        const float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
        QuadOut out;
        out.position = float4(corners[vid], 0, 1);
        out.uv = uvs[vid];
        return out;
    }

    fragment float4 quad_fragment(QuadOut in [[stage_in]],
                                  texture2d<float> image [[texture(0)]],
                                  sampler imageSampler [[sampler(0)]]) {
        // The canvas is opaque. Alpha is ignored until transparency (a checkerboard) lands;
        // `noneSkip` bitmaps carry an undefined fourth byte.
        return float4(image.sample(imageSampler, in.uv).rgb, 1.0);
    }
    """

    static func makePipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "NooVeu image quad"
        descriptor.vertexFunction = library.makeFunction(name: "quad_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "quad_fragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Trilinear sampling for zoomed-out views; nearest-neighbour for pixel peeping.
    static func makeSampler(device: MTLDevice, pixelGrid: Bool) -> MTLSamplerState? {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = pixelGrid ? .nearest : .linear
        descriptor.mipFilter = pixelGrid ? .notMipmapped : .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        descriptor.maxAnisotropy = 1
        return device.makeSamplerState(descriptor: descriptor)
    }
}
