import CoreGraphics

/// When a downsampled first view should be replaced by the full-resolution decode.
public enum UpgradePolicy {
    /// - Parameters:
    ///   - textureLongestSide: Longest side of the bitmap on screen, in pixels.
    ///   - sourceLongestSide: Longest side of the source file, in pixels.
    ///   - zoom: Device pixels per source pixel.
    ///   - isCustomZoom: Whether the user chose the zoom. A fitted view never upgrades: the first
    ///     view is sized for it.
    public static func shouldUpgrade(
        textureLongestSide: Int, sourceLongestSide: Int, zoom: CGFloat, isCustomZoom: Bool
    ) -> Bool {
        // Nothing sharper exists once the texture is as large as the source, or as large as a
        // texture can be. This is only a first filter: a full-resolution decode can still come out
        // no larger than the texture on screen (a very wide JPEG is subsampled to stay within the
        // texture limit), so the caller must also try an upgrade only once per image.
        guard isCustomZoom,
              textureLongestSide < sourceLongestSide,
              textureLongestSide < ImageDecoder.maxTextureDimension else { return false }
        let sharpUntil = CGFloat(textureLongestSide) / CGFloat(sourceLongestSide)
        return zoom > sharpUntil * 1.05
    }
}
