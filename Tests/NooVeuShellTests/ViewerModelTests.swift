import Foundation
import NooVeuCore
import Testing
@testable import NooVeuShell

@Suite("ViewerModel", .timeLimit(.minutes(1)))
@MainActor
struct ViewerModelTests {
    private let photos = ["a.jpg", "b.jpg", "c.jpg"]

    private func harness(_ names: [String]? = nil, firstViewSide: Int = 1000) -> Harness {
        Harness(firstViewSide: firstViewSide, folders: ["/photos": names ?? photos])
    }

    private func zoomedIn(_ h: Harness, zoom: CGFloat = 0.6) {
        h.view = .init(zoom: zoom, isFitMode: false)
    }

    // MARK: Opening

    @Test func openingAFileShowsItAndListsItsFolder() async throws {
        let h = harness()

        h.model.open(h.url("/photos", "b.jpg"))
        await h.settle()

        #expect(h.shownNames == ["b.jpg"])
        #expect(h.titles.last == "b.jpg")
        #expect(h.lastSubtitle.hasPrefix("2 / 3"), "got \(h.lastSubtitle)")
        #expect(h.lastSubtitle.contains("400×300"))
    }

    @Test func openingAFolderShowsItsFirstImage() async throws {
        let h = harness()

        h.model.open(URL(fileURLWithPath: "/photos"))
        await h.settle()

        #expect(h.shownNames == ["a.jpg"])
        #expect(h.lastSubtitle.hasPrefix("1 / 3"))
    }

    @Test func anEmptyFolderSaysSoAndShowsNothing() async throws {
        let h = Harness(folders: ["/empty": []])

        h.model.open(URL(fileURLWithPath: "/empty"))
        await h.settle()

        #expect(h.shows.isEmpty)
        #expect(h.titles.last == "empty")
        #expect(h.lastSubtitle == "No images in this folder")
    }

    @Test func aFolderThatCannotBeReadSaysSo() async throws {
        let h = Harness()

        h.model.open(URL(fileURLWithPath: "/nosuch"))
        await h.settle()

        #expect(h.lastSubtitle == "Can't read this folder")
        #expect(h.titles.last == "nosuch")
    }

    @Test func aFileWhoseFolderCannotBeListedStillOpensButCannotFlip() async throws {
        let h = Harness()  // no listing for /photos

        h.model.open(h.url("/photos", "b.jpg"))
        await h.settle()
        h.model.perform(.nextImage)
        await h.settle()

        #expect(h.shownNames == ["b.jpg"])
        #expect(!h.lastSubtitle.contains(" / "), "no position without a listing: \(h.lastSubtitle)")
    }

    @Test func theOpenedPathIsMadeCanonicalForTheCacheAndTheListing() async throws {
        // A real folder and a symlink to it: two spellings of one place must meet the cache and
        // the listing as one.
        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent("NooVeuModel-\(UUID().uuidString)", isDirectory: true)
        let alias = FileManager.default.temporaryDirectory
            .appendingPathComponent("NooVeuAlias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: real)
        }
        try Data().write(to: real.appendingPathComponent("b.jpg"))
        let canonicalFolder = FolderNavigator.canonical(real.appendingPathComponent("b.jpg")).deletingLastPathComponent().path
        let h = Harness(folders: [canonicalFolder: ["b.jpg"]])

        h.model.open(alias.appendingPathComponent("b.jpg"))
        await h.settle()

        #expect(h.log.all.contains("listing:\(canonicalFolder)"), "\(h.log.all)")
        #expect(!h.log.all.contains("listing:\(alias.path)"))
        #expect(h.shownNames == ["b.jpg"])
    }

    // MARK: Flipping

    @Test func flippingForwardAndBackWrapsAtTheEnds() async throws {
        let h = harness()
        h.model.open(h.url("/photos", "b.jpg"))
        await h.settle()

        for command in [ViewerCommand.nextImage, .nextImage, .previousImage] {
            h.model.perform(command)
            await h.settle()
        }

        #expect(h.shownNames == ["b.jpg", "c.jpg", "a.jpg", "c.jpg"])
    }

    @Test func homeAndEndJumpToTheEnds() async throws {
        let h = harness()
        h.model.open(h.url("/photos", "b.jpg"))
        await h.settle()

        h.model.perform(.lastImage); await h.settle()
        h.model.perform(.firstImage); await h.settle()

        #expect(h.shownNames == ["b.jpg", "c.jpg", "a.jpg"])
    }

    @Test func aFolderOfOneImageHasNowhereToGo() async throws {
        let h = harness(["only.jpg"])
        h.model.open(h.url("/photos", "only.jpg"))
        await h.settle()

        h.model.perform(.nextImage); await h.settle()
        h.model.perform(.previousImage); await h.settle()

        #expect(h.shownNames == ["only.jpg"], "reloading would only lose the zoom")
    }

    @Test func onlyNavigationCommandsAreHandledByTheModel() {
        let h = harness()

        #expect(h.model.perform(.nextImage))
        #expect(!h.model.perform(.zoomIn))
        #expect(!h.model.perform(.toggleFullScreen))
        #expect(!h.model.perform(.zoomToFit))
    }

    @Test func aFileThatFailsShowsTheMessageAndTheNextFlipRecovers() async throws {
        let h = harness()
        h.fail("decode:b.jpg")

        h.model.open(h.url("/photos", "b.jpg"))
        await h.settle()

        #expect(h.shows.isEmpty)
        #expect(h.clears == 1)
        #expect(h.lastSubtitle == "Can't open this file")

        h.model.perform(.nextImage)
        await h.settle()

        #expect(h.shownNames == ["c.jpg"])
        #expect(!h.lastSubtitle.contains("Can't"))
    }

    @Test func anUploadThatFailsIsTreatedLikeADecodeThatFails() async throws {
        let h = harness()
        h.fail("prepare:b.jpg")

        h.model.open(h.url("/photos", "b.jpg"))
        await h.settle()

        #expect(h.shows.isEmpty)
        #expect(h.lastSubtitle == "Can't open this file")
    }

    // MARK: Racing results

    @Test func aDecodeThatFinishesAfterTheUserMovedOnIsDropped() async throws {
        let h = harness()
        await h.gates.hold("decode:a.jpg")
        h.model.open(h.url("/photos", "a.jpg"))
        await h.settleListing()

        h.model.perform(.nextImage)  // to b, while a is still decoding
        await h.settle()
        await h.gates.release("decode:a.jpg")
        try await h.letPendingWorkRun()

        #expect(h.shownNames == ["b.jpg"])
        #expect(h.log.count("prepare:a.jpg") == 0, "a's result must not even be uploaded")
    }

    @Test func anUploadThatFinishesAfterTheUserMovedOnIsDropped() async throws {
        let h = harness()
        await h.gates.hold("prepare:a.jpg")
        h.model.open(h.url("/photos", "a.jpg"))
        await h.settleListing()
        try await h.waitFor("a to be uploading") { h.log.count("prepare:a.jpg") == 1 }

        h.model.perform(.nextImage)
        await h.settle()
        await h.gates.release("prepare:a.jpg")
        try await h.letPendingWorkRun()

        #expect(h.shownNames == ["b.jpg"])
    }

    @Test func nothingIsShownIntoAClosedWindow() async throws {
        let h = harness()
        await h.gates.hold("decode:a.jpg")
        h.model.open(h.url("/photos", "a.jpg"))
        try await h.waitFor("a to be decoding") { h.log.count("decode:a.jpg:1000") == 1 }

        h.model.close()
        await h.gates.release("decode:a.jpg")
        try await h.letPendingWorkRun()

        #expect(h.shows.isEmpty)
        #expect(h.log.count("prepare:a.jpg") == 0)
    }

    // MARK: Status line

    @Test func theStatusLineShowsTheImageOnScreenNotTheOneLoading() async throws {
        let h = harness()
        h.model.open(h.url("/photos", "b.jpg"))
        await h.settle()
        await h.gates.hold("decode:c.jpg")

        h.model.perform(.nextImage)  // c is loading
        h.model.transformChanged()
        #expect(h.lastSubtitle.hasPrefix("2 / 3"), "still b: \(h.lastSubtitle)")

        await h.gates.release("decode:c.jpg")
        await h.settle()
        #expect(h.lastSubtitle.hasPrefix("3 / 3"), "now c: \(h.lastSubtitle)")
    }

    @Test func theSurfaceIsToldJustBeforeAnImageAppears() async throws {
        let h = harness()

        h.model.open(h.url("/photos", "b.jpg"))
        await h.settle()

        let log = h.log.all
        let willShow = try #require(log.firstIndex(of: "willShow"))
        let show = try #require(log.firstIndex(of: "show:b.jpg"))
        #expect(willShow < show)
    }

    // MARK: Preloading

    @Test func preloadingFollowsTheDirectionOfTravelAndStaysInOrder() async throws {
        let h = harness(["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"])
        h.model.open(h.url("/photos", "b.jpg"))
        await h.settleListing()

        h.model.perform(.nextImage)
        h.model.perform(.nextImage)  // two flips with no pause
        await h.settle()

        let preloads = h.log.all.filter { $0.hasPrefix("preload:") }
        #expect(preloads == [
            "preload:c.jpg,a.jpg,d.jpg,e.jpg",  // at b, heading forward
            "preload:d.jpg,b.jpg,e.jpg,a.jpg",  // at c
            "preload:e.jpg,c.jpg,a.jpg,b.jpg",  // at d
        ])
    }

    // MARK: Closing and cancelling

    @Test func closingWhileAFolderIsBeingListedShowsNothing() async throws {
        let h = harness()
        await h.gates.hold("listing:/photos")
        h.model.open(URL(fileURLWithPath: "/photos"))
        try await h.waitFor("the listing to start") { h.log.count("listing:/photos") == 1 }

        h.model.close()
        await h.gates.release("listing:/photos")
        try await h.letPendingWorkRun()

        #expect(h.shows.isEmpty)
        #expect(h.log.count(prefix: "decode:") == 0, "no first image may be requested for a closed window")
    }

    @Test func aClosedModelStartsNoNewWork() async throws {
        let h = harness()
        h.model.open(h.url("/photos", "b.jpg"))
        await h.settle()
        let decodesBefore = h.log.count(prefix: "decode:")
        let preloadsBefore = h.log.count(prefix: "preload:")

        h.model.close()
        h.view = .init(zoom: 0.6, isFitMode: false)
        h.model.transformChanged()  // would normally start the full-resolution upgrade
        h.model.screenChanged(longestSide: 3000)
        h.model.perform(.nextImage)
        h.model.open(h.url("/photos", "c.jpg"))
        await h.settle()

        #expect(h.log.count(prefix: "full:") == 0)
        #expect(h.log.count(prefix: "decode:") == decodesBefore)
        #expect(h.log.count(prefix: "preload:") == preloadsBefore)
        #expect(h.shownNames == ["b.jpg"])
        #expect(h.model.firstViewSide == 1000, "a closed window does not follow a display change")
    }

    @Test func aDecodeCancelledByClosingLeavesNoErrorBehind() async throws {
        let h = harness()
        await h.gates.hold("decode:a.jpg")
        h.model.open(h.url("/photos", "a.jpg"))
        try await h.waitFor("a to be decoding") { h.log.count("decode:a.jpg:1000") == 1 }

        h.model.close()
        await h.gates.release("decode:a.jpg")  // the fake, like the real scheduler, throws CancellationError
        try await h.letPendingWorkRun()

        #expect(h.clears == 0)
        #expect(!h.subtitles.contains { $0.contains("Can't") })
    }

    // MARK: Failures

    @Test func aFlipThatFailsClearsTheOldImageAndExplainsWhy() async throws {
        let h = harness()
        h.model.open(h.url("/photos", "b.jpg"))
        await h.settle()
        h.fail("decode:c.jpg")

        h.model.perform(.nextImage)
        await h.settle()

        #expect(h.clears == 1)
        #expect(h.lastSubtitle == "Can't open this file", "the old image's details must not linger: \(h.lastSubtitle)")
        #expect(h.titles.last == "c.jpg")
        // With the old image gone there is nothing to upgrade, whatever the zoom.
        h.view = .init(zoom: 0.6, isFitMode: false)
        h.model.transformChanged()
        await h.settle()
        #expect(h.log.count(prefix: "full:") == 0)
    }

    @Test func aFailureFromAnImageTheUserAlreadyLeftIsIgnored() async throws {
        let h = harness()
        h.fail("decode:a.jpg")
        await h.gates.hold("decode:a.jpg")
        h.model.open(h.url("/photos", "a.jpg"))
        await h.settleListing()

        h.model.perform(.nextImage)  // on to b while a is still decoding
        await h.settle()
        await h.gates.release("decode:a.jpg")  // a now fails, too late to matter
        try await h.letPendingWorkRun()

        #expect(h.shownNames == ["b.jpg"])
        #expect(h.clears == 0, "a stale failure must not wipe the image now on screen")
        #expect(!h.subtitles.contains { $0.contains("Can't") })
    }

    // MARK: Status line and requests

    @Test func thePositionAppearsWhenTheListingArrivesAfterTheImage() async throws {
        let h = harness()
        await h.gates.hold("listing:/photos")

        h.model.open(h.url("/photos", "b.jpg"))
        try await h.waitFor("b to be shown") { h.shownNames == ["b.jpg"] }
        #expect(!h.lastSubtitle.contains(" / "), "no position yet: \(h.lastSubtitle)")

        await h.gates.release("listing:/photos")
        await h.settle()

        #expect(h.lastSubtitle.hasPrefix("2 / 3"), "\(h.lastSubtitle)")
    }

    @Test func everyRequestForTheImageTheUserIsWaitingForIsVisiblePriority() async throws {
        let h = harness()
        h.model.open(h.url("/photos", "b.jpg"))
        await h.settle()
        h.view = .init(zoom: 0.6, isFitMode: false)
        h.model.transformChanged()
        await h.settle()

        let priorities = h.log.all.filter { $0.hasPrefix("priority:") }
        #expect(priorities == ["priority:decode:b.jpg=visible", "priority:full:b.jpg=visible"])
    }

    // MARK: Preloading

    @Test func aLaterPreloadWaitsForTheEarlierOne() async throws {
        // Two flips close together: the second preload list must not reach the scheduler before the
        // first, or the older list could drop what the newer one wants.
        let h = harness(["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"])
        await h.gates.hold("preload:c.jpg")  // the first list, headed by c, is slow
        h.model.open(h.url("/photos", "b.jpg"))
        await h.settleListing()
        try await h.waitFor("the first preload to start") { h.log.count(prefix: "preload:") == 1 }

        h.model.perform(.nextImage)
        try await h.letPendingWorkRun()
        #expect(h.log.count(prefix: "preload:") == 1, "the second list must wait: \(h.log.all)")

        await h.gates.release("preload:c.jpg")
        await h.settle()
        #expect(h.log.all.filter { $0.hasPrefix("preload:") }
                == ["preload:c.jpg,a.jpg,d.jpg,e.jpg", "preload:d.jpg,b.jpg,e.jpg,a.jpg"])
    }
}
