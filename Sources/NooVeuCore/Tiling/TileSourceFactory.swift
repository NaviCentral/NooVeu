import CoreGraphics
import Foundation

/// Which images are tiled, and at what detail.
public enum LargeImagePolicy {
    /// Images with a longest side above this are tiled (about 32 MP and up). Smaller ones keep the
    /// whole-texture path, which is simpler and already well tested.
    public static let tilingThreshold = 8192

    public static func shouldTile(sourceSize: PixelSize) -> Bool {
        sourceSize.longestSide > tilingThreshold
    }

    /// The smallest power of two `f` such that the image reduced to 1/`f` of its size fits in
    /// `budgetBytes` as 8-bit RGBA. 1 means it fits at full detail. (The budget is approximate: the
    /// decoded rows are padded to the system's alignment, a few dozen bytes each.)
    public static func detailFactor(for size: PixelSize, budgetBytes: Int) -> Int {
        var factor = 1
        while factor < 64, bytes(size, factor: factor) > budgetBytes { factor *= 2 }
        return factor
    }

    private static func bytes(_ size: PixelSize, factor: Int) -> Int {
        // File headers are untrusted: a huge claimed size must not overflow.
        let (pixels, overflow) = ((size.width + factor - 1) / factor).multipliedReportingOverflow(by: (size.height + factor - 1) / factor)
        let (total, overflow2) = pixels.multipliedReportingOverflow(by: 4)
        return overflow || overflow2 ? Int.max : total
    }
}

public enum TileSourceFactory {
    /// Formats stored as a grid of tiles, which ImageIO can decode a region of cheaply.
    static let regionTypes: Set<String> = ["public.heic", "public.heics", "public.heif", "public.avif", "public.avis", "public.avci"]

    /// A region source whose typical tile takes longer than this is not trusted: the file decodes
    /// everything each time (a HEIC stored as one big frame, say). Typical tiles take 10 to 15 ms; a
    /// whole-image decode takes 75 ms (24 MP) to 300 ms (100 MP) or more, so this sits well clear of
    /// both, including on a heavily loaded machine (where tiles take a few times longer).
    public static let defaultRegionTileBudget: Duration = .milliseconds(120)

    /// The best source for the image at `url`. Blocking: it can take 100 to 500 ms (decoding the image
    /// into a buffer, or timing a few tiles), so call it off the main thread, or use `makeAsync`.
    ///
    /// - Parameters:
    ///   - bufferBudget: Memory the decoded buffer may use when the format has no region decode.
    ///     A larger image is decoded at a reduced detail that fits (see `TileSource.detailFactor`). The
    ///     figure is for what is held afterwards: JPEG briefly needs about as much again while it is
    ///     decoded, and other formats about twice (ImageIO decodes them whole before reducing).
    ///   - regionTileBudget: How long a typical region-decoded tile may take before the buffer is used.
    /// - Throws: `DecodeError`.
    public static func make(
        url: URL, bufferBudget: Int = 512 << 20, tileSize: Int = 512, border: Int = 1,
        regionTileBudget: Duration = defaultRegionTileBudget
    ) throws -> any TileSource {
        guard let probe = ImageDecoder.probe(url) else { throw DecodeError.unreadable(url) }

        if regionTypes.contains(probe.typeIdentifier ?? ""),
           let region = try? RegionTileSource(url: url, tileSize: tileSize, border: border),
           let time = try? region.measureTypicalTile(), time <= regionTileBudget {
            return region
        }

        let factor = LargeImagePolicy.detailFactor(for: probe.orientedSize, budgetBytes: bufferBudget)
        let decoded = try ImageDecoder.decodeForTiling(url, detailFactor: factor)
        // The detail actually held, from the real sizes (ImageIO may round the reduced size).
        let detail = Double(probe.orientedSize.longestSide) / Double(max(decoded.pixelSize.longestSide, 1))
        return BufferTileSource(image: decoded.cgImage, trueSize: probe.orientedSize, detailFactor: detail,
                                tileSize: tileSize, border: border)
    }

    /// `make`, off the calling task's thread.
    public static func makeAsync(
        url: URL, bufferBudget: Int = 512 << 20, tileSize: Int = 512, border: Int = 1,
        regionTileBudget: Duration = defaultRegionTileBudget
    ) async throws -> any TileSource {
        try await TileDecodeQueue.run {
            try make(url: url, bufferBudget: bufferBudget, tileSize: tileSize, border: border, regionTileBudget: regionTileBudget)
        }
    }
}
