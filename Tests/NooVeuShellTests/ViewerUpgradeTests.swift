import Foundation
import NooVeuCore
import Testing
@testable import NooVeuShell

/// Upgrading a downsampled first view to the full-resolution decode, and following the window to
/// another display. Images are 400×300; a first view is 100×75, sharp up to a zoom of 0.25.
@Suite("ViewerModel upgrade and screen changes", .timeLimit(.minutes(1)))
@MainActor
struct ViewerUpgradeTests {
    private func opened(_ names: [String] = ["a.jpg", "b.jpg", "c.jpg"]) async -> Harness {
        let h = Harness(firstViewSide: 1000, folders: ["/photos": names])
        h.model.open(h.url("/photos", "b.jpg"))
        await h.settle()
        return h
    }

    private func zoomIn(_ h: Harness, to zoom: CGFloat = 0.6) async {
        h.view = .init(zoom: zoom, isFitMode: false)
        h.model.transformChanged()
        await h.settle()
    }

    // MARK: When to upgrade

    @Test func zoomingPastWhatTheFirstViewCanShowReplacesItWithTheFullDecodeWithoutMovingTheView() async throws {
        let h = await opened()
        #expect(h.shows == [Shown(name: "b.jpg", textureSize: Harness.firstViewSize, resetView: true)])

        await zoomIn(h)

        #expect(h.log.count("full:b.jpg") == 1)
        #expect(h.shows.last == Shown(name: "b.jpg#full", textureSize: Harness.sourceSize, resetView: false))
        #expect(h.lastSubtitle.contains("60%"), "\(h.lastSubtitle)")
    }

    @Test func eachImageIsUpgradedAtMostOnce() async throws {
        let h = await opened()

        await zoomIn(h)
        await zoomIn(h, to: 1.5)
        await zoomIn(h, to: 3)

        #expect(h.log.count("full:b.jpg") == 1)
        #expect(h.shows.count == 2)
    }

    @Test func aFittedViewIsNeverUpgraded() async throws {
        let h = await opened()
        h.view = .init(zoom: 0.9, isFitMode: true)

        h.model.transformChanged()
        await h.settle()

        #expect(h.log.count(prefix: "full:") == 0)
    }

    @Test func aZoomTheFirstViewCanStillShowSharplyIsNotUpgraded() async throws {
        let h = await opened()

        await zoomIn(h, to: 0.25)  // the texture's own resolution; the threshold is 5% above it
        await zoomIn(h, to: 0.26)

        #expect(h.log.count(prefix: "full:") == 0)
    }

    @Test func aFailedUpgradeIsNotRetriedOnEveryPan() async throws {
        let h = await opened()
        h.fail("full:b.jpg")

        await zoomIn(h)
        await zoomIn(h, to: 0.7)
        await zoomIn(h, to: 0.8)

        #expect(h.log.count("full:b.jpg") == 1)
        #expect(h.shownNames == ["b.jpg"], "the first view stays")
    }

    @Test func anUploadThatFailsDuringAnUpgradeIsNotRetriedEither() async throws {
        let h = await opened()
        h.fail("prepare:b.jpg#full")

        await zoomIn(h)
        await zoomIn(h, to: 0.7)

        #expect(h.log.count("full:b.jpg") == 1)
        #expect(h.shownNames == ["b.jpg"])
    }

    @Test func aFileSavedOverWithADifferentSizeStartsTheViewAfresh() async throws {
        let h = await opened()
        h.overrideFullSource("b.jpg", PixelSize(width: 500, height: 300))

        await zoomIn(h)

        #expect(h.shows.last == Shown(name: "b.jpg#full", textureSize: PixelSize(width: 500, height: 300), resetView: true))
    }

    @Test func aFullDecodeNoLargerThanTheTextureOnScreenDoesNotLoopForever() async throws {
        // A very wide JPEG is subsampled to stay within the GPU's texture limit: "full resolution"
        // can come out the same size as the first view, which would look like something sharper
        // to fetch every time the new texture is shown.
        let h = await opened()
        h.overrideFullSource("b.jpg", Harness.firstViewSize)

        await zoomIn(h)
        await zoomIn(h, to: 0.7)
        await zoomIn(h, to: 0.8)

        #expect(h.log.count("full:b.jpg") == 1)
    }

    // MARK: Racing

    @Test func anUpgradeThatFinishesAfterTheUserMovedOnIsDropped() async throws {
        let h = await opened()
        await h.gates.hold("full:b.jpg")
        h.view = .init(zoom: 0.6, isFitMode: false)
        h.model.transformChanged()
        try await h.waitFor("the upgrade to start") { h.log.count("full:b.jpg") == 1 }

        h.view = .init(zoom: 0.2, isFitMode: true)  // a new image starts fitted
        h.model.perform(.nextImage)
        await h.settle()
        await h.gates.release("full:b.jpg")
        try await h.letPendingWorkRun()

        #expect(h.shownNames == ["b.jpg", "c.jpg"], "the late full-resolution b must not appear")
        #expect(h.log.count("prepare:b.jpg#full") == 0)
    }

    @Test func showingTheUpgradeDoesNotTriggerAnotherOne() async throws {
        // The real canvas reports a change when it shows an image; the model must already know the
        // new image needs nothing more by then.
        let h = await opened()
        #expect(h.reenter)

        await zoomIn(h)

        #expect(h.log.count("full:b.jpg") == 1)
    }

    @Test func theModelKnowsTheNewImageBeforeTheSurfaceReportsAChange() async throws {
        // Showing an image makes the real canvas report a change straight away. The status line
        // built from inside that callback must already describe the new image (first view: 100
        // wide, uploads in 10 ms; full: 400 wide, 40 ms), and the same holds for the first show.
        let h = await opened()

        await zoomIn(h)

        #expect(h.subtitlesDuringShow.count == 2)
        #expect(h.subtitlesDuringShow[0].contains("upload 10 ms"), "\(h.subtitlesDuringShow[0])")
        #expect(h.subtitlesDuringShow[1].contains("upload 40 ms"), "\(h.subtitlesDuringShow[1])")
    }

    @Test func anImageStillLoadingIsNotUpgradedUnderTheOneOnScreen() async throws {
        let h = await opened()
        await h.gates.hold("decode:c.jpg")
        h.model.perform(.nextImage)  // c is loading; b is still on screen
        try await h.waitFor("c to be decoding") { h.log.count("decode:c.jpg:1000") == 1 }

        // The user zooms in on b meanwhile. (No `settle()` here: c's decode is held on purpose.)
        h.view = .init(zoom: 0.6, isFitMode: false)
        h.model.transformChanged()
        try await h.letPendingWorkRun()

        #expect(h.log.count(prefix: "full:") == 0, "nothing sharper to fetch while the shown image is not the current one: \(h.log.all)")

        h.view = .init(zoom: 0.2, isFitMode: true)  // a new image starts fitted
        await h.gates.release("decode:c.jpg")
        await h.settle()
        #expect(h.shownNames == ["b.jpg", "c.jpg"])
    }

    // MARK: Screens

    @Test func movingToALargerDisplayDecodesAgainAtItsSizeWhileFitted() async throws {
        let h = await opened()
        #expect(h.log.count("decode:b.jpg:1000") == 1)

        h.model.screenChanged(longestSide: 2000)
        await h.settle()

        #expect(h.log.count("decode:b.jpg:2000") == 1)
        #expect(h.model.firstViewSide == 2000)
    }

    @Test func movingToALargerDisplayAlsoPreloadsAtTheNewSize() async throws {
        let h = await opened()

        h.model.screenChanged(longestSide: 2000)
        await h.settle()

        #expect(h.log.count("preload@2000") >= 1, "neighbours must be decoded for the new display, too: \(h.log.all)")
    }

    @Test func movingToASmallerDisplayChangesNothing() async throws {
        let h = await opened()

        h.model.screenChanged(longestSide: 500)
        await h.settle()

        #expect(h.log.count(prefix: "decode:b.jpg:500") == 0)
        #expect(h.model.firstViewSide == 1000)
    }

    @Test func aZoomTheUserChoseIsKeptWhenTheDisplayChanges() async throws {
        let h = await opened()
        h.view = .init(zoom: 0.2, isFitMode: false)

        h.model.screenChanged(longestSide: 3000)
        await h.settle()

        #expect(h.log.count("decode:b.jpg:3000") == 0, "no reload that would reset the view")
        #expect(h.model.firstViewSide == 3000, "but later images use the new size")
    }
}
