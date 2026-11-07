import Foundation
import Testing
@testable import NooVeuCore

@Suite("FlipState")
struct FlipStateTests {
    private func listing(_ count: Int) -> FolderListing {
        FolderListing(folder: URL(fileURLWithPath: "/x"), items: (0..<count).map { URL(fileURLWithPath: "/x/\($0).jpg") })
    }

    private func state(_ count: Int = 10, at index: Int = 0) -> FlipState {
        var state = FlipState()
        state.setListing(listing(count), current: URL(fileURLWithPath: "/x/\(index).jpg"))
        return state
    }

    @Test func startsAtTheOpenedFile() {
        let state = state(at: 4)

        #expect(state.index == 4)
        #expect(state.currentURL?.lastPathComponent == "4.jpg")
        #expect(state.position?.number == 5 && state.position?.count == 10)
    }

    @Test func hasNoPositionWhenTheOpenedFileIsNotInTheListing() {
        var state = FlipState()
        state.setListing(listing(3), current: URL(fileURLWithPath: "/elsewhere/gone.jpg"))

        #expect(state.index == nil)
        #expect(state.step(+1) == nil)
        #expect(state.preloadURLs.isEmpty)
    }

    @Test func steppingWrapsAtBothEnds() {
        var forward = state(5, at: 4)
        #expect(forward.step(+1)?.lastPathComponent == "0.jpg")

        var back = state(5, at: 0)
        #expect(back.step(-1)?.lastPathComponent == "4.jpg")
    }

    @Test func aFolderOfOneImageHasNowhereToGo() {
        var single = state(1, at: 0)

        // Stepping would land on the image already shown; reloading it would only lose the zoom.
        #expect(single.step(+1) == nil)
        #expect(single.step(-1) == nil)
        #expect(single.index == 0)
        #expect(single.preloadURLs.isEmpty)
    }

    @Test func preloadFavoursTheDirectionOfTravel() {
        var state = state(10, at: 5)

        _ = state.step(+1)  // now at 6, heading forward
        #expect(state.preloadURLs.map(\.lastPathComponent) == ["7.jpg", "5.jpg", "8.jpg", "9.jpg"])

        _ = state.step(-1)  // back at 5, heading backward
        #expect(state.preloadURLs.map(\.lastPathComponent) == ["4.jpg", "6.jpg", "3.jpg", "2.jpg"])
    }

    @Test func jumpsStayInsideTheListing() {
        var state = state(10, at: 5)

        #expect(state.jumpToFirst()?.lastPathComponent == "0.jpg")
        #expect(state.jumpToLast()?.lastPathComponent == "9.jpg")
        #expect(state.jump(to: 10) == nil)
        #expect(state.jump(to: -1) == nil)
        #expect(state.index == 9, "a rejected jump changes nothing")
    }

    @Test func jumpsSetTheDirectionPreloadingFavours() {
        var state = state(10, at: 5)

        _ = state.jumpToLast()
        #expect(state.direction == -1, "after End, the images before it matter")
        #expect(state.preloadURLs.map(\.lastPathComponent).first == "8.jpg")

        _ = state.jumpToFirst()
        #expect(state.direction == 1)
        #expect(state.preloadURLs.map(\.lastPathComponent).first == "1.jpg")
    }

    @Test func preloadWrapsAtTheEndsOfTheFolder() {
        let last = state(10, at: 9)  // heading forward from the last image

        #expect(last.preloadURLs.map(\.lastPathComponent) == ["0.jpg", "8.jpg", "1.jpg", "2.jpg"])

        var first = state(10, at: 0)
        _ = first.jumpToLast()
        _ = first.jumpToFirst()
        _ = first.step(-1)  // wraps to the last image, heading backward
        #expect(first.currentURL?.lastPathComponent == "9.jpg")
        #expect(first.preloadURLs.map(\.lastPathComponent) == ["8.jpg", "0.jpg", "7.jpg", "6.jpg"])
    }

    @Test func aNewListingReplacesTheOldPosition() {
        var state = state(10, at: 7)
        _ = state.step(-1)

        state.setListing(listing(3), current: URL(fileURLWithPath: "/x/1.jpg"))

        #expect(state.index == 1)
        #expect(state.position?.count == 3)
    }

    @Test func jumpingToTheImageAlreadyShownChangesNothing() {
        var state = state(10, at: 0)

        #expect(state.jumpToFirst() == nil, "Home on the first image would only reload it")
        #expect(state.index == 0)
        #expect(state.jump(to: 0) == nil)
        #expect(state.jumpToLast()?.lastPathComponent == "9.jpg")
        #expect(state.jumpToLast() == nil)
    }

    @Test func aHugeStepDoesNotTrap() {
        var state = state(10, at: 3)

        #expect(state.step(Int.max) != nil)
        #expect(state.index != nil)
    }

    @Test func anEmptyListingHasNoImages() {
        var state = FlipState()
        state.setListing(listing(0), current: nil)

        #expect(state.jumpToFirst() == nil)
        #expect(state.jumpToLast() == nil)
        #expect(state.currentURL == nil)
    }
}
