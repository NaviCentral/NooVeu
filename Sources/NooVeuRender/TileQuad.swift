import CoreGraphics
import Metal
import NooVeuCore

/// One tile to draw: where it goes on screen and which part of its texture it shows.
public struct TileQuad: @unchecked Sendable {
    public let id: TileID
    public let texture: MTLTexture
    /// Position in Metal clip space as (minX, minY, maxX, maxY).
    public let clipRect: SIMD4<Float>
    /// The part of the texture shown, as (u0, v0, u1, v1) with row 0 on top: the tile's content,
    /// without its border. Sampling at the edge reaches into the border, so neighbouring tiles blend
    /// as one image.
    public let uvRect: SIMD4<Float>

    /// Places `tile` for `transform`, or nil when it is entirely outside the view.
    ///
    /// The transform's image size must be the source's true size in pixels. The tile's footprint
    /// comes from the source (`sourceArea(of:)`), so reduced-detail sources and partial last pixels
    /// land where they belong, and two neighbours compute their shared edge from the same number.
    public static func make(_ id: TileID, tile: ResidentTile, source: any TileSource, transform: ViewTransform) -> TileQuad? {
        guard transform.viewSize.width > 0, transform.viewSize.height > 0 else { return nil }
        let grid = source.grid
        let area = source.sourceArea(of: id)
        guard area.width > 0, area.height > 0 else { return nil }

        let topLeft = transform.viewPoint(forImagePoint: CGPoint(x: area.minX, y: area.minY))
        let bottomRight = transform.viewPoint(forImagePoint: CGPoint(x: area.maxX, y: area.maxY))
        // View points have y up, so the area's top edge has the larger y.
        let clip = SIMD4<Float>(
            Float(topLeft.x / transform.viewSize.width * 2 - 1),
            Float(bottomRight.y / transform.viewSize.height * 2 - 1),
            Float(bottomRight.x / transform.viewSize.width * 2 - 1),
            Float(topLeft.y / transform.viewSize.height * 2 - 1))
        guard clip.z > -1, clip.x < 1, clip.w > -1, clip.y < 1 else { return nil }

        // The texture holds the padded area; the content starts `border` in (less at the image's edge),
        // and covers the area in level pixels (the last pixel may be partial: the area is clipped).
        let content = grid.contentRect(of: id), padded = tile.paddedRect
        let levelPixelsPerSource = 1 / (Double(1 << id.level) * max(source.detailFactor, 1))
        let width = Double(tile.texture.width), height = Double(tile.texture.height)
        let u0 = Double(content.x - padded.x), v0 = Double(content.y - padded.y)
        let uv = SIMD4<Float>(
            Float(u0 / width), Float(v0 / height),
            Float((u0 + area.width * levelPixelsPerSource) / width),
            Float((v0 + area.height * levelPixelsPerSource) / height))
        return TileQuad(id: id, texture: tile.texture, clipRect: clip, uvRect: uv)
    }
}
