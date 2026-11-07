import CoreGraphics

public enum ScreenMath {
    /// The longest side of a display in pixels, from its size in points and its backing scale.
    /// `fallback` when there is no display to ask.
    public static func longestSide(of size: CGSize?, scale: CGFloat, fallback: Int = 3840) -> Int {
        guard let size, size.width > 0, size.height > 0, scale > 0 else { return fallback }
        return Int((max(size.width, size.height) * scale).rounded())
    }
}
