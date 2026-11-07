import CoreGraphics
import Testing
@testable import NooVeuRender

@Suite("ViewTransform")
struct ViewTransformTests {
    /// A 4000×3000 image in an 800×600-point window on a Retina (2×) display.
    private func makeTransform() -> ViewTransform {
        ViewTransform(imageSize: CGSize(width: 4000, height: 3000),
                      viewSize: CGSize(width: 800, height: 600), backingScale: 2)
    }

    @Test func fitShowsTheWholeImageCentred() {
        let transform = makeTransform()

        #expect(transform.mode == .fit)
        #expect(transform.zoom == 0.4)  // 1600 device pixels across / 4000 image pixels
        #expect(transform.imageRectInView == CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(transform.clipRect == SIMD4<Float>(-1, -1, 1, 1))
    }

    @Test func fitNeverEnlargesSmallImages() {
        let transform = ViewTransform(imageSize: CGSize(width: 100, height: 50),
                                      viewSize: CGSize(width: 800, height: 600), backingScale: 2)

        #expect(transform.zoom == 1)
        #expect(transform.imageRectInView.size == CGSize(width: 50, height: 25))
        #expect(transform.imageRectInView.midX == 400)
    }

    @Test func zoomKeepsThePixelUnderThePointerInPlace() {
        var transform = makeTransform()
        let pointer = CGPoint(x: 600, y: 450)
        let before = transform.imagePoint(forViewPoint: pointer)

        transform.setZoom(1.7, anchor: pointer)

        #expect(transform.mode == .custom)
        let after = transform.viewPoint(forImagePoint: before)
        #expect(abs(after.x - pointer.x) < 0.001)
        #expect(abs(after.y - pointer.y) < 0.001)
    }

    @Test func zoomingToAWholeNumberMovesThePointerPixelByAtMostHalfADevicePixel() {
        var transform = makeTransform()
        let pointer = CGPoint(x: 600, y: 450)
        let before = transform.imagePoint(forViewPoint: pointer)

        transform.setZoom(2, anchor: pointer)

        // Snapping the image to whole device pixels can shift it by half a device pixel (a
        // quarter of a point on a 2x display) when the zoom lands on a whole number.
        let after = transform.viewPoint(forImagePoint: before)
        #expect(abs(after.x - pointer.x) <= 0.25 + 1e-9)
        #expect(abs(after.y - pointer.y) <= 0.25 + 1e-9)
    }

    @Test func hitTestingMatchesTheDrawnRectangleAtWholeNumberZoom() {
        // An odd-sized image: its snapped rectangle's corners must map back to image corners.
        var transform = ViewTransform(imageSize: CGSize(width: 1001, height: 501),
                                      viewSize: CGSize(width: 750, height: 400), backingScale: 2)
        transform.setZoom(1)
        let rect = transform.imageRectInView

        let topLeft = transform.imagePoint(forViewPoint: CGPoint(x: rect.minX, y: rect.maxY))
        let bottomRight = transform.imagePoint(forViewPoint: CGPoint(x: rect.maxX, y: rect.minY))

        #expect(abs(topLeft.x) < 1e-6 && abs(topLeft.y) < 1e-6)
        #expect(abs(bottomRight.x - 1001) < 1e-6 && abs(bottomRight.y - 501) < 1e-6)
    }

    @Test func viewAndImagePointsRoundTrip() {
        var transform = makeTransform()
        transform.setZoom(1.7, anchor: CGPoint(x: 100, y: 500))
        let point = CGPoint(x: 1234, y: 987)

        let back = transform.imagePoint(forViewPoint: transform.viewPoint(forImagePoint: point))

        #expect(abs(back.x - point.x) < 0.001 && abs(back.y - point.y) < 0.001)
    }

    @Test func imageTopLeftIsAtTheViewTop() {
        var transform = makeTransform()
        transform.setZoom(1)  // actual pixels, centred
        let topLeft = transform.viewPoint(forImagePoint: .zero)

        // AppKit's y axis points up, so the image's first row is above the view centre.
        #expect(topLeft.y > 300)
        #expect(topLeft.x < 400)
    }

    @Test func panningStopsAtTheImageEdge() {
        var transform = makeTransform()
        transform.setZoom(1)

        transform.pan(by: CGSize(width: 100_000, height: 0))  // drag far to the right

        // The image's left edge stops at the view's left edge.
        #expect(abs(transform.imageRectInView.minX) < 0.001)
    }

    @Test func panningDoesNothingWhenTheImageFits() {
        var transform = makeTransform()

        transform.pan(by: CGSize(width: 50, height: -30))

        #expect(transform.imageRectInView == CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    @Test func panningMovesTheImageByTheDragDistanceInBothAxes() {
        var transform = makeTransform()
        transform.setZoom(1)
        let before = transform.imageRectInView

        transform.pan(by: CGSize(width: 10, height: 10))  // drag right and up

        let after = transform.imageRectInView
        #expect(abs(after.minX - before.minX - 10) < 0.001)
        #expect(abs(after.minY - before.minY - 10) < 0.001)

        transform.pan(by: CGSize(width: -25, height: -40))  // drag left and down
        let later = transform.imageRectInView
        #expect(abs(later.minX - after.minX + 25) < 0.001)
        #expect(abs(later.minY - after.minY + 40) < 0.001)
    }

    @Test func aPannedImageMapsToTheMatchingClipRect() {
        var transform = makeTransform()
        transform.setZoom(1)
        let before = transform.clipRect

        transform.pan(by: CGSize(width: 40, height: 30))

        // 40 points of an 800-point-wide view is 0.1 of clip space; 30 of 600 is 0.1 as well.
        #expect(abs(transform.clipRect.x - before.x - 0.1) < 1e-4)
        #expect(abs(transform.clipRect.z - before.z - 0.1) < 1e-4)
        #expect(abs(transform.clipRect.y - before.y - 0.1) < 1e-4)
        #expect(abs(transform.clipRect.w - before.w - 0.1) < 1e-4)
    }

    @Test func zoomingNearACornerNeverShowsEmptySpaceBesideTheImage() {
        var transform = makeTransform()

        transform.setZoom(2, anchor: CGPoint(x: 0, y: 0))
        let bottomLeft = transform.imageRectInView
        transform.setZoom(1, anchor: CGPoint(x: 800, y: 600))
        let topRight = transform.imageRectInView

        for rect in [bottomLeft, topRight] {
            #expect(rect.minX <= 0.001 && rect.maxX >= 799.999)
            #expect(rect.minY <= 0.001 && rect.maxY >= 599.999)
        }
    }

    @Test func aStandardDisplayFitsAtItsOwnScale() {
        let transform = ViewTransform(imageSize: CGSize(width: 4000, height: 3000),
                                      viewSize: CGSize(width: 800, height: 600), backingScale: 1)

        #expect(transform.zoom == 0.2)
        #expect(transform.imageRectInView.size == CGSize(width: 800, height: 600))
    }

    @Test func actualPixelsLandOnWholeDevicePixelsEvenForOddSizes() {
        // A 1001-pixel image in a 750-point (1500-pixel) view would sit on a half pixel.
        var transform = ViewTransform(imageSize: CGSize(width: 1001, height: 501),
                                      viewSize: CGSize(width: 750, height: 400), backingScale: 2)
        transform.setZoom(1)

        let rect = transform.imageRectInView

        #expect((rect.minX * 2).rounded() == rect.minX * 2)
        #expect((rect.minY * 2).rounded() == rect.minY * 2)
        #expect(rect.width * 2 == 1001)
    }

    @Test func resizingToTheSameSizeChangesNothing() {
        var transform = makeTransform()
        transform.setZoom(1.3, anchor: CGPoint(x: 300, y: 200))
        let before = transform

        transform.setViewSize(transform.viewSize, backingScale: transform.backingScale)

        #expect(transform == before)
    }

    @Test func resizingRefitsOnlyInFitMode() {
        var fitted = makeTransform()
        fitted.setViewSize(CGSize(width: 400, height: 300), backingScale: 2)
        #expect(fitted.zoom == 0.2)

        var zoomed = makeTransform()
        zoomed.setZoom(1.5)
        zoomed.setViewSize(CGSize(width: 400, height: 300), backingScale: 2)
        #expect(zoomed.zoom == 1.5)
    }

    @Test func zoomIsClampedToItsRange() {
        var transform = makeTransform()

        transform.setZoom(1_000)
        #expect(transform.zoom == ViewTransform.zoomRange.upperBound)
        transform.setZoom(0)
        #expect(transform.zoom == ViewTransform.zoomRange.lowerBound)
    }

    @Test func pixelGridAppearsAtTwoHundredPercent() {
        var transform = makeTransform()
        transform.setZoom(1.99)
        #expect(!transform.showsPixelGrid)
        transform.setZoom(2)
        #expect(transform.showsPixelGrid)
    }
}
