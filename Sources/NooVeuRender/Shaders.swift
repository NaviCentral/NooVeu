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

    // Draws one tile: a quad covering `rect`, sampling the part `uvRect` (u0, v0, u1, v1; row 0 on
    // top) of a texture that also holds the tile's border, so smooth sampling at the tile's edge
    // sees the neighbour's pixels and no seam shows.
    vertex QuadOut tile_vertex(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]],
                               constant float4 &uvRect [[buffer(1)]]) {
        const float2 corners[4] = {
            float2(rect.x, rect.y), float2(rect.z, rect.y),
            float2(rect.x, rect.w), float2(rect.z, rect.w)
        };
        const float2 uvs[4] = {
            float2(uvRect.x, uvRect.w), float2(uvRect.z, uvRect.w),
            float2(uvRect.x, uvRect.y), float2(uvRect.z, uvRect.y)
        };
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

    /// Compiles the shader source (the expensive part; do it once and share the library).
    static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        try device.makeLibrary(source: source, options: nil)
    }

    static func makePipeline(library: MTLLibrary, pixelFormat: MTLPixelFormat, tiles: Bool = false) throws -> MTLRenderPipelineState {
        let device = library.device
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = tiles ? "NooVeu tile quad" : "NooVeu image quad"
        descriptor.vertexFunction = library.makeFunction(name: tiles ? "tile_vertex" : "quad_vertex")
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
