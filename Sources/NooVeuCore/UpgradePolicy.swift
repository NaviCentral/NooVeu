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
        // texture can be (a 20000 px source decodes to 16384 whatever the request).
        guard isCustomZoom,
              textureLongestSide < sourceLongestSide,
              textureLongestSide < ImageDecoder.maxTextureDimension else { return false }
        let sharpUntil = CGFloat(textureLongestSide) / CGFloat(sourceLongestSide)
        return zoom > sharpUntil * 1.05
    }
}
