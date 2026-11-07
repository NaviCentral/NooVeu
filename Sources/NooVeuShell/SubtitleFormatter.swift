import CoreGraphics
import Foundation
import NooVeuCore

/// What a window remembers about the image on screen. Sizes and timings only: the bitmap itself
/// belongs to the scheduler's cache and must not be pinned by a window (after an upgrade it can
/// be 400 MB).
public struct ShownImageInfo: Equatable, Sendable {
    public let sourceSize: PixelSize
    public let textureSize: PixelSize
    public let decodeDuration: Duration
    public let uploadDuration: Duration

    public init(sourceSize: PixelSize, textureSize: PixelSize, decodeDuration: Duration, uploadDuration: Duration) {
        self.sourceSize = sourceSize
        self.textureSize = textureSize
        self.decodeDuration = decodeDuration
        self.uploadDuration = uploadDuration
    }
}

/// The text under a window's title.
public enum SubtitleFormatter {
    /// - Parameters:
    ///   - position: "3 / 120": where the image on screen is in its folder.
    ///   - shown: the image on screen, if there is one.
    ///   - zoom: device pixels per source pixel.
    ///   - error: shown instead of image details when there is no image.
    public static func text(position: (number: Int, count: Int)?, shown: ShownImageInfo?, zoom: CGFloat, error: String?) -> String {
        var parts: [String] = []
        if let position {
            parts.append("\(position.number) / \(position.count)")
        }
        if let shown {
            parts.append(shown.sourceSize.description)
            parts.append("\(Int((zoom * 100).rounded()))%")
            parts.append(String(format: "decode %.0f ms, upload %.0f ms",
                                shown.decodeDuration.milliseconds, shown.uploadDuration.milliseconds))
        } else if let error {
            parts.append(error)
        }
        return parts.joined(separator: "  ·  ")
    }
}
