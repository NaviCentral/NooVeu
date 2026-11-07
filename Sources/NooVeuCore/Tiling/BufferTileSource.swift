import CoreGraphics
import Foundation

/// Serves tiles from an image decoded once into memory we own.
///
/// This is the source for JPEG, PNG and every format ImageIO cannot decode a region of: for those the
/// whole image has to be decoded anyway, and decoding it once into our own buffer (rather than letting
/// ImageIO cache it behind a lazy `CGImage`, or decoding it again for every tile) is both fastest and
/// the only way to know what memory it uses. Coarser levels are made from the buffer on demand.
///
/// Build one with `TileSourceFactory`. The image given to `init` must already be fully decoded and
/// upright (as `ImageDecoder` returns it): a lazy image would decode on first draw, and
/// `retainedBytes` would understate what is held.
final class BufferTileSource: TileSource, @unchecked Sendable {
    let grid: TileGrid
    let trueSize: PixelSize
    let detailFactor: Double
    private let image: CGImage

    /// - Parameters:
    ///   - image: The whole image, upright and fully decoded.
    ///   - trueSize: The image's real size, when `image` is a reduced version of it.
    ///   - detailFactor: Source pixels per pixel of `image`, when it is a reduced version.
    init(image: CGImage, trueSize: PixelSize? = nil, detailFactor: Double = 1, tileSize: Int = 512, border: Int = 1) {
        self.image = image
        self.detailFactor = detailFactor
        self.trueSize = trueSize ?? PixelSize(width: Int((Double(image.width) * detailFactor).rounded()),
                                              height: Int((Double(image.height) * detailFactor).rounded()))
        self.grid = TileGrid(sourceSize: PixelSize(width: image.width, height: image.height), tileSize: tileSize, border: border)
    }

    var retainedBytes: Int { image.bytesPerRow * image.height }

    func tile(_ id: TileID) async throws -> TileBitmap {
        try await TileDecodeQueue.run { try self.renderTile(id) }
    }

    func renderTile(_ id: TileID) throws -> TileBitmap {
        guard grid.isValid(id) else { throw TileError.invalidTile(id) }
        let padded = grid.paddedRect(of: id)
        let scale = 1 << id.level

        // The tile's area in level-0 pixels, clipped to the image.
        let x0 = padded.x * scale, y0 = padded.y * scale
        let x1 = min(padded.maxX * scale, image.width), y1 = min(padded.maxY * scale, image.height)
        // Read a little beyond it at coarse levels, so the scaling filter has the neighbours' pixels
        // and this tile's border equals the neighbour's edge (no seam).
        let margin = TileMargin.sourcePixels(level: id.level)
        let cx0 = max(x0 - margin, 0), cy0 = max(y0 - margin, 0)
        // The crop is a whole number of this level's pixels. Core Graphics rounds the size of a
        // scaled drawing, so a fraction of a pixel at the far edge would shift the sampling in the tiles
        // that reach it, and they would disagree with their neighbours. The source pixels left out are
        // those of the image's last, partial level pixel, which `replicateInnerNeighbour` fills in.
        // (An image smaller than a level pixel keeps what it has.)
        let cx1 = max(cx0 + (min(x1 + margin, image.width) - cx0) / scale * scale, min(cx0 + 1, image.width))
        let cy1 = max(cy0 + (min(y1 + margin, image.height) - cy0) / scale * scale, min(cy0 + 1, image.height))

        guard let region = image.cropping(to: CGRect(x: cx0, y: cy0, width: cx1 - cx0, height: cy1 - cy0)),
              let context = TileBitmapLayout.makeContext(width: padded.width, height: padded.height, colorSpace: image.colorSpace)
        else { throw TileError.renderFailed(id) }

        // Always draw at exactly 1/scale, so a pixel means the same in every tile and neighbours agree
        // along their border. (Stretching an edge tile to fill its bitmap would not.) Where the image's
        // last pixel at this level covers fewer source pixels, the drawing leaves it partly transparent;
        // `TileEdge.replicateInnerNeighbour` replaces it.
        let inverse = 1.0 / Double(scale)
        // `.medium`, not `.high`: the high-quality filter's output near a crop's edge depends on how the
        // crop was cut (measured: up to 40/255 on noise even with a wide margin), so neighbouring tiles
        // would disagree along their shared border and show seams. `.medium` gives the same pixels
        // whatever the crop.
        context.interpolationQuality = id.level == 0 ? .none : .medium
        // Core Graphics' y axis points up, the image's rows count down.
        context.draw(region, in: CGRect(x: -Double(x0 - cx0) * inverse,
                                        y: Double(padded.height) - Double(cy1 - y0) * inverse,
                                        width: Double(cx1 - cx0) * inverse, height: Double(cy1 - cy0) * inverse))
        TileEdge.replicateInnerNeighbour(in: context, padded: padded, grid: grid, level: id.level)
        guard let bitmap = context.makeImage() else { throw TileError.renderFailed(id) }
        return TileBitmap(id: id, image: bitmap, paddedRect: padded)
    }
}
