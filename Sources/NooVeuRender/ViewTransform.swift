import CoreGraphics

/// Maps between image pixels and view points for zoom and pan.
///
/// Conventions: image coordinates have their origin at the top-left with y down; view
/// coordinates are AppKit points with the origin at the bottom-left and y up. `zoom` is in
/// device pixels per image pixel, so 1 means actual pixels on any display.
public struct ViewTransform: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// Whole image visible; refits when the view resizes.
        case fit
        /// A zoom the user chose; kept when the view resizes.
        case custom
    }

    public static let zoomRange: ClosedRange<CGFloat> = 0.01...64

    public private(set) var imageSize: CGSize
    public private(set) var viewSize: CGSize
    public private(set) var backingScale: CGFloat
    public private(set) var zoom: CGFloat = 1
    /// The image pixel shown at the centre of the view.
    public private(set) var center: CGPoint = .zero
    public private(set) var mode: Mode = .fit

    public init(imageSize: CGSize = .zero, viewSize: CGSize = .zero, backingScale: CGFloat = 2) {
        self.imageSize = imageSize
        self.viewSize = viewSize
        self.backingScale = backingScale
        fit()
    }

    /// The zoom that shows the whole image. Never above 1: small images are shown at
    /// actual pixels rather than blown up.
    public var fitZoom: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return 1 }
        let fit = min(viewSize.width * backingScale / imageSize.width,
                      viewSize.height * backingScale / imageSize.height)
        return min(fit, 1)
    }

    /// At 200% and above, pixels are drawn as sharp squares rather than smoothed.
    public var showsPixelGrid: Bool { zoom >= 2 }

    /// Sets the image's logical size: the source's size in pixels, which can be larger than the
    /// texture on screen when a downsampled version is shown first. Starts fitted.
    public mutating func setImageSize(_ size: CGSize) {
        imageSize = size
        fit()
    }

    public mutating func setViewSize(_ size: CGSize, backingScale: CGFloat) {
        viewSize = size
        self.backingScale = backingScale
        if mode == .fit {
            fit()
        } else {
            clampCenter()
        }
    }

    public mutating func fit() {
        mode = .fit
        zoom = fitZoom
        center = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
    }

    /// Sets the zoom while keeping the image pixel under `anchor` (a view point) in place.
    /// With no anchor, zooms about the view's centre.
    public mutating func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil) {
        let anchor = anchor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let fixed = imagePoint(forViewPoint: anchor)
        zoom = min(max(newZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        mode = .custom
        center = CGPoint(
            x: fixed.x - (anchor.x - viewSize.width / 2) * backingScale / zoom,
            y: fixed.y + (anchor.y - viewSize.height / 2) * backingScale / zoom
        )
        clampCenter()
    }

    public mutating func zoom(by factor: CGFloat, anchor: CGPoint? = nil) {
        setZoom(zoom * factor, anchor: anchor)
    }

    /// Moves the image by `delta` view points (positive height moves it up).
    public mutating func pan(by delta: CGSize) {
        center.x -= delta.width * backingScale / zoom
        center.y += delta.height * backingScale / zoom
        clampCenter()
    }

    public func imagePoint(forViewPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: center.x + (point.x - viewSize.width / 2) * backingScale / zoom,
            y: center.y - (point.y - viewSize.height / 2) * backingScale / zoom
        )
    }

    public func viewPoint(forImagePoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: viewSize.width / 2 + (point.x - center.x) * zoom / backingScale,
            y: viewSize.height / 2 - (point.y - center.y) * zoom / backingScale
        )
    }

    /// The image's rectangle in view points.
    ///
    /// At a whole-number zoom the origin is snapped to a whole device pixel. Without that, an
    /// image whose size differs from the view's by an odd number of pixels sits on a half-pixel
    /// offset, and smooth sampling blurs every pixel (a 1:1 view would not be sharp).
    public var imageRectInView: CGRect {
        let topLeft = viewPoint(forImagePoint: .zero)
        let width = imageSize.width * zoom / backingScale
        let height = imageSize.height * zoom / backingScale
        var rect = CGRect(x: topLeft.x, y: topLeft.y - height, width: width, height: height)
        if zoom >= 1, abs(zoom - zoom.rounded()) < 1e-6 {
            rect.origin.x = (rect.origin.x * backingScale).rounded() / backingScale
            rect.origin.y = (rect.origin.y * backingScale).rounded() / backingScale
        }
        return rect
    }

    /// The image's rectangle in Metal clip space as (minX, minY, maxX, maxY), each -1…1.
    public var clipRect: SIMD4<Float> {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let rect = imageRectInView
        return SIMD4(
            Float(rect.minX / viewSize.width * 2 - 1),
            Float(rect.minY / viewSize.height * 2 - 1),
            Float(rect.maxX / viewSize.width * 2 - 1),
            Float(rect.maxY / viewSize.height * 2 - 1)
        )
    }

    /// Per axis: an image narrower than the view is centred; a wider one cannot be dragged
    /// so far that empty space shows at its edge.
    private mutating func clampCenter() {
        let visibleWidth = viewSize.width * backingScale / zoom
        let visibleHeight = viewSize.height * backingScale / zoom
        center.x = Self.clamp(center.x, visible: visibleWidth, extent: imageSize.width)
        center.y = Self.clamp(center.y, visible: visibleHeight, extent: imageSize.height)
    }

    private static func clamp(_ value: CGFloat, visible: CGFloat, extent: CGFloat) -> CGFloat {
        if visible >= extent { return extent / 2 }
        return min(max(value, visible / 2), extent - visible / 2)
    }
}
