import Foundation
import Synchronization
import Testing
@testable import NooVeuCore

/// A fake decoder that counts calls, tracks how many run at once, and can be held open
/// until the test releases it.
final class FakeDecoder: Sendable {
    private struct State {
        var calls: [URL] = []
        var active = 0
        var peakActive = 0
    }

    private let state = Mutex(State())
    private let gate: DispatchSemaphore?

    /// - Parameter gated: when true, every decode waits for `release()`.
    init(gated: Bool = false) {
        gate = gated ? DispatchSemaphore(value: 0) : nil
    }

    var calls: [URL] { state.withLock { $0.calls } }
    var peakActive: Int { state.withLock { $0.peakActive } }
    func callCount(for url: URL) -> Int { calls.filter { $0 == url }.count }

    func release(_ count: Int = 1) {
        for _ in 0..<count { gate?.signal() }
    }

    var decoder: DecodeScheduler.Decoder {
        { [self] url, _ in
            state.withLock {
                $0.calls.append(url)
                $0.active += 1
                $0.peakActive = max($0.peakActive, $0.active)
            }
            gate?.wait()
            state.withLock { $0.active -= 1 }
            if url.lastPathComponent.hasPrefix("bad") { throw DecodeError.decodeFailed(url) }
            return TestImages.decoded(width: 10, height: 10)
        }
    }
}

private func url(_ name: String) -> URL { URL(fileURLWithPath: "/photos/\(name)") }

/// Waits until `condition` holds, failing the test after two seconds.
private func eventually(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition never became true")
}

@Suite("DecodeScheduler")
struct DecodeSchedulerTests {
    @Test func secondRequestIsServedFromTheCache() async throws {
        let fake = FakeDecoder()
        let scheduler = DecodeScheduler(costLimit: 1 << 20, decoder: fake.decoder)

        _ = try await scheduler.image(for: url("a.jpg"))
        _ = try await scheduler.image(for: url("a.jpg"))

        #expect(fake.callCount(for: url("a.jpg")) == 1)
        #expect(await scheduler.statistics.cacheHits == 1)
    }

    @Test func concurrentRequestsShareOneDecode() async throws {
        let fake = FakeDecoder(gated: true)
        let scheduler = DecodeScheduler(costLimit: 1 << 20, decoder: fake.decoder)

        async let first = scheduler.image(for: url("a.jpg"))
        async let second = scheduler.image(for: url("a.jpg"))
        try await eventually { await scheduler.statistics.joinedInFlight == 1 }
        fake.release()
        _ = try await (first, second)

        #expect(fake.callCount(for: url("a.jpg")) == 1)
    }

    @Test func aFailureIsNotCachedSoARepeatedRequestDecodesAgain() async throws {
        let fake = FakeDecoder()
        let scheduler = DecodeScheduler(costLimit: 1 << 20, decoder: fake.decoder)

        await #expect(throws: DecodeError.self) { try await scheduler.image(for: url("bad.jpg")) }
        await #expect(throws: DecodeError.self) { try await scheduler.image(for: url("bad.jpg")) }

        #expect(fake.callCount(for: url("bad.jpg")) == 2)
    }

    @Test func neverExceedsItsLimitAndKeepsASlotFreeForTheVisibleImage() async throws {
        let fake = FakeDecoder(gated: true)
        let scheduler = DecodeScheduler(costLimit: 1 << 30, maxConcurrentDecodes: 3, decoder: fake.decoder)
        #expect(scheduler.maxConcurrentPreloads == 2)

        await scheduler.preload((0..<6).map { url("\($0).jpg") })
        try await eventually { fake.calls.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.calls.count == 2, "preloads stop one short of the limit")

        // The image the user flips to starts at once, while both preloads are still running.
        async let visible = scheduler.image(for: url("now.jpg"))
        try await eventually { fake.calls.count == 3 }
        fake.release(7)
        _ = try await visible
        try await eventually { await scheduler.cachedCount == 7 }

        #expect(fake.peakActive == 3)
    }

    @Test func aVisibleRequestStartsAtOnceWhileAPreloadRunsAndPreloadsWaitForTheirSlot() async throws {
        let fake = FakeDecoder(gated: true)
        let scheduler = DecodeScheduler(costLimit: 1 << 30, maxConcurrentDecodes: 1, decoder: fake.decoder)

        await scheduler.preload([url("p1.jpg"), url("p2.jpg"), url("p3.jpg")])
        try await eventually { fake.calls.count == 1 }  // p1 holds the only preload slot
        async let visible = scheduler.image(for: url("v.jpg"))
        try await eventually { fake.calls.count == 2 }  // v starts at once, in a burst slot
        #expect(fake.calls.map(\.lastPathComponent) == ["p1.jpg", "v.jpg"])
        fake.release(4)
        _ = try await visible
        try await eventually { fake.calls.count == 4 }

        #expect(fake.calls.map(\.lastPathComponent) == ["p1.jpg", "v.jpg", "p2.jpg", "p3.jpg"])
    }

    @Test func movingOnDropsQueuedPreloadsThatAreNoLongerWanted() async throws {
        let fake = FakeDecoder(gated: true)
        let scheduler = DecodeScheduler(costLimit: 1 << 30, maxConcurrentDecodes: 1, decoder: fake.decoder)

        await scheduler.preload([url("1.jpg"), url("2.jpg"), url("3.jpg")])
        try await eventually { fake.calls.count == 1 }
        // The user flipped far away: only 8 and 9 are wanted now.
        await scheduler.preload([url("8.jpg"), url("9.jpg")])
        fake.release(3)
        try await eventually { await scheduler.cachedCount == 3 }

        #expect(fake.calls.map(\.lastPathComponent) == ["1.jpg", "8.jpg", "9.jpg"])
        #expect(await scheduler.statistics.droppedPreloads == 2)
    }

    @Test func cacheStaysWithinItsCostLimit() async throws {
        let fake = FakeDecoder()
        let oneImage = TestImages.decoded(width: 10, height: 10).byteCost
        let scheduler = DecodeScheduler(costLimit: oneImage * 3, decoder: fake.decoder)

        for index in 0..<10 {
            _ = try await scheduler.image(for: url("\(index).jpg"))
        }

        #expect(await scheduler.cachedCount == 3)
        #expect(await scheduler.cachedCost <= oneImage * 3)
        #expect(await scheduler.cachedImage(for: url("9.jpg")) != nil)
        #expect(await scheduler.cachedImage(for: url("0.jpg")) == nil)
    }

    @Test func aChangedFileIsDecodedAgain() async throws {
        let folder = try TemporaryFolder()
        let file = TestImages.write(width: 64, height: 32, to: folder.file("a.png"))
        let scheduler = DecodeScheduler(costLimit: 1 << 24)

        let before = try await scheduler.image(for: file)
        TestImages.write(width: 10, height: 10, to: file)
        let after = try await scheduler.image(for: file)

        #expect(before.pixelSize == PixelSize(width: 64, height: 32))
        #expect(after.pixelSize == PixelSize(width: 10, height: 10))
    }

    @Test func aCancelledVisibleRequestLeavesTheQueue() async throws {
        let fake = FakeDecoder(gated: true)
        // One slot plus two burst slots: three visible decodes fill everything.
        let scheduler = DecodeScheduler(costLimit: 1 << 30, maxConcurrentDecodes: 1, decoder: fake.decoder)

        let running = (1...3).map { n in Task { try await scheduler.image(for: url("v\(n).jpg")) } }
        try await eventually { fake.calls.count == 3 }
        let doomed = Task { try await scheduler.image(for: url("doomed.jpg")) }
        try await eventually { await scheduler.queuedCount == 1 }
        doomed.cancel()
        try await eventually { await scheduler.queuedCount == 0 }
        fake.release(4)
        for task in running { _ = try await task.value }

        await #expect(throws: CancellationError.self) { try await doomed.value }
        // The three tasks reach the scheduler in no fixed order; what matters is that the
        // cancelled request was never decoded.
        #expect(Set(fake.calls.map(\.lastPathComponent)) == ["v1.jpg", "v2.jpg", "v3.jpg"])
        #expect(fake.callCount(for: url("doomed.jpg")) == 0)
        #expect(await scheduler.statistics.cancelledRequests == 1)
    }

    @Test func aRunningDecodeStillServesTheOtherWaiterWhenOneIsCancelled() async throws {
        let fake = FakeDecoder(gated: true)
        let scheduler = DecodeScheduler(costLimit: 1 << 30, decoder: fake.decoder)

        let first = Task { try await scheduler.image(for: url("a.jpg")) }
        let second = Task { try await scheduler.image(for: url("a.jpg")) }
        try await eventually { await scheduler.statistics.joinedInFlight == 1 }
        first.cancel()
        try await eventually { await scheduler.statistics.cancelledRequests == 1 }
        fake.release()

        _ = try await second.value
        #expect(fake.callCount(for: url("a.jpg")) == 1)
        await #expect(throws: CancellationError.self) { try await first.value }
    }

    @Test func aVisibleRequestJoinsARunningPreload() async throws {
        let fake = FakeDecoder(gated: true)
        let scheduler = DecodeScheduler(costLimit: 1 << 30, decoder: fake.decoder)

        await scheduler.preload([url("a.jpg")])
        try await eventually { fake.calls.count == 1 }
        async let visible = scheduler.image(for: url("a.jpg"))
        try await eventually { await scheduler.statistics.joinedInFlight == 1 }
        fake.release()
        _ = try await visible

        #expect(fake.callCount(for: url("a.jpg")) == 1)
    }

    @Test func aPendingPreloadIsPromotedWhenTheUserAsksForIt() async throws {
        let fake = FakeDecoder(gated: true)
        let scheduler = DecodeScheduler(costLimit: 1 << 30, maxConcurrentDecodes: 1, decoder: fake.decoder)

        await scheduler.preload([url("p1.jpg"), url("p2.jpg"), url("p3.jpg")])
        try await eventually { fake.calls.count == 1 }
        async let wanted = scheduler.image(for: url("p3.jpg"))
        try await eventually { await scheduler.statistics.joinedInFlight == 1 }
        fake.release(3)
        _ = try await wanted
        try await eventually { fake.calls.count == 3 }

        #expect(fake.calls.map(\.lastPathComponent) == ["p1.jpg", "p3.jpg", "p2.jpg"])
    }

    @Test func aFailureIsSharedByEveryWaiter() async throws {
        let fake = FakeDecoder(gated: true)
        let scheduler = DecodeScheduler(costLimit: 1 << 30, decoder: fake.decoder)

        let first = Task { try await scheduler.image(for: url("bad.jpg")) }
        let second = Task { try await scheduler.image(for: url("bad.jpg")) }
        try await eventually { await scheduler.statistics.joinedInFlight == 1 }
        fake.release()

        await #expect(throws: DecodeError.self) { try await first.value }
        await #expect(throws: DecodeError.self) { try await second.value }
        #expect(fake.callCount(for: url("bad.jpg")) == 1)
    }

    @Test func aFileThatFailedIsNotRetriedByPreloadButIsByAnExplicitRequest() async throws {
        let fake = FakeDecoder()
        let scheduler = DecodeScheduler(costLimit: 1 << 30, decoder: fake.decoder)

        await scheduler.preload([url("bad.jpg")])
        try await eventually { await scheduler.failedCount == 1 }
        await scheduler.preload([url("bad.jpg")])
        await scheduler.preload([url("bad.jpg")])
        #expect(await scheduler.statistics.decodesStarted == 1)

        await #expect(throws: DecodeError.self) { try await scheduler.image(for: url("bad.jpg")) }
        #expect(await scheduler.statistics.decodesStarted == 2)
    }

    @Test func preloadsAreReorderedNearestFirstEachTime() async throws {
        let fake = FakeDecoder(gated: true)
        let scheduler = DecodeScheduler(costLimit: 1 << 30, maxConcurrentDecodes: 1, decoder: fake.decoder)

        await scheduler.preload([url("r.jpg"), url("a.jpg"), url("b.jpg"), url("c.jpg")])
        try await eventually { fake.calls.count == 1 }  // r is running
        // The user moved: c is now nearest, a is no longer wanted, d is new.
        await scheduler.preload([url("r.jpg"), url("c.jpg"), url("b.jpg"), url("d.jpg")])
        fake.release(4)
        try await eventually { fake.calls.count == 4 }

        #expect(fake.calls.map(\.lastPathComponent) == ["r.jpg", "c.jpg", "b.jpg", "d.jpg"])
        #expect(await scheduler.statistics.droppedPreloads == 1)
    }

    @Test func purgeDuringARunningDecodeStillDeliversIt() async throws {
        let fake = FakeDecoder(gated: true)
        let scheduler = DecodeScheduler(costLimit: 1 << 30, decoder: fake.decoder)

        let request = Task { try await scheduler.image(for: url("a.jpg")) }
        try await eventually { fake.calls.count == 1 }
        await scheduler.purge()
        fake.release()

        _ = try await request.value
        #expect(await scheduler.cachedCount == 1)
    }

    @Test func anExplicitPreloadPriorityRequestSurvivesALaterPreloadCall() async throws {
        let fake = FakeDecoder(gated: true)
        let scheduler = DecodeScheduler(costLimit: 1 << 30, maxConcurrentDecodes: 1, decoder: fake.decoder)

        let holder = Task { try await scheduler.image(for: url("hold.jpg")) }
        try await eventually { fake.calls.count == 1 }
        let asked = Task { try await scheduler.image(for: url("asked.jpg"), priority: .preload) }
        try await eventually { await scheduler.queuedCount == 1 }
        await scheduler.preload([url("other.jpg")])  // does not mention asked.jpg
        fake.release(3)

        _ = try await holder.value
        try await eventually { fake.callCount(for: url("asked.jpg")) == 1 }
        // If the request was lost, fail here rather than wait on it forever.
        guard fake.callCount(for: url("asked.jpg")) == 1 else {
            asked.cancel()
            return
        }
        _ = try await asked.value
    }

    @Test func aCancelledPromotedPreloadGoesBackToBeingAPreload() async throws {
        let fake = FakeDecoder(gated: true)
        let scheduler = DecodeScheduler(costLimit: 1 << 30, maxConcurrentDecodes: 1, decoder: fake.decoder)

        // hold runs as the preload; two visible decodes fill the burst slots; x waits as a preload.
        await scheduler.preload([url("hold.jpg"), url("x.jpg")])
        let busy = (1...2).map { n in Task { try await scheduler.image(for: url("v\(n).jpg")) } }
        try await eventually { fake.calls.count == 3 }
        #expect(await scheduler.queuedCount == 1)
        // The user asks for x: promoted, but no slot is free. Then they move on.
        let promoted = Task { try await scheduler.image(for: url("x.jpg")) }
        try await eventually { await scheduler.statistics.joinedInFlight == 1 }
        promoted.cancel()
        try await eventually { await scheduler.statistics.cancelledRequests == 1 }

        #expect(await scheduler.queuedCount == 1, "x is still wanted by the last preload call")
        fake.release(5)
        for task in busy { _ = try await task.value }
        try await eventually { fake.callCount(for: url("x.jpg")) == 1 }
    }

    @Test func aNewModificationTimeAloneInvalidatesTheCache() async throws {
        let folder = try TemporaryFolder()
        try folder.touch("a.jpg", contents: "same size every time")
        let fake = FakeDecoder()
        let scheduler = DecodeScheduler(costLimit: 1 << 30, decoder: fake.decoder)

        _ = try await scheduler.image(for: folder.file("a.jpg"))
        _ = try await scheduler.image(for: folder.file("a.jpg"))
        #expect(fake.callCount(for: folder.file("a.jpg")) == 1)

        // Same bytes and size, saved a minute later.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: folder.file("a.jpg").path)
        _ = try await scheduler.image(for: folder.file("a.jpg"))

        #expect(fake.callCount(for: folder.file("a.jpg")) == 2)
    }

    @Test func fastFlippingNeverLeavesTheNewImageWaitingBehindAbandonedDecodes() async throws {
        let fake = FakeDecoder(gated: true)
        let scheduler = DecodeScheduler(costLimit: 1 << 30, maxConcurrentDecodes: 2, decoder: fake.decoder)

        await scheduler.preload([url("p1.jpg"), url("p2.jpg")])
        try await eventually { fake.calls.count == 1 }  // one preload slot
        let first = Task { try await scheduler.image(for: url("v1.jpg")) }
        try await eventually { fake.calls.count == 2 }  // both slots busy
        first.cancel()  // the user flips on; v1's decode cannot be interrupted
        try await eventually { await scheduler.statistics.cancelledRequests == 1 }
        async let second = scheduler.image(for: url("v2.jpg"))

        try await eventually { fake.calls.count == 3 }
        #expect(fake.calls.map(\.lastPathComponent) == ["p1.jpg", "v1.jpg", "v2.jpg"], "v2 starts without waiting")
        fake.release(5)
        _ = try await second
    }

    @Test func abandonedDecodesCannotPileUpWithoutLimit() async throws {
        let fake = FakeDecoder(gated: true)
        let scheduler = DecodeScheduler(costLimit: 1 << 30, maxConcurrentDecodes: 2, decoder: fake.decoder)

        // A user holding the arrow key: each image is requested, then abandoned a moment later.
        var abandoned: [Task<DecodedImage, Error>] = []
        for n in 0..<10 {
            abandoned.append(Task { try await scheduler.image(for: url("v\(n).jpg")) })
            try await Task.sleep(for: .milliseconds(15))
            abandoned.last!.cancel()
        }
        try await Task.sleep(for: .milliseconds(50))

        // The bound is what matters, so a request that registers late cannot make this flaky.
        #expect(fake.peakActive <= 2 + 2, "never more than the limit plus two burst slots")
        #expect(fake.peakActive >= 3, "the burst slots were used")
        fake.release(20)
        for task in abandoned { _ = try? await task.value }
    }

    @Test func aRequestFromAnAlreadyCancelledTaskNeverStartsADecode() async throws {
        let fake = FakeDecoder()
        let scheduler = DecodeScheduler(costLimit: 1 << 30, decoder: fake.decoder)

        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await scheduler.image(for: url("a.jpg"))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await scheduler.statistics.decodesStarted == 0)
    }

    @Test func purgeAlsoForgetsWhichFilesFailed() async throws {
        let fake = FakeDecoder()
        let scheduler = DecodeScheduler(costLimit: 1 << 30, decoder: fake.decoder)
        await scheduler.preload([url("bad.jpg")])
        try await eventually { await scheduler.failedCount == 1 }

        await scheduler.purge()

        #expect(await scheduler.failedCount == 0)
        await scheduler.preload([url("bad.jpg")])
        #expect(await scheduler.statistics.decodesStarted == 2, "forgotten, so tried again")
    }

    @Test func preloadSkipsWhatIsAlreadyCached() async throws {
        let fake = FakeDecoder()
        let scheduler = DecodeScheduler(costLimit: 1 << 30, decoder: fake.decoder)
        _ = try await scheduler.image(for: url("a.jpg"))

        await scheduler.preload([url("a.jpg")])

        #expect(await scheduler.statistics.decodesStarted == 1)
        #expect(await scheduler.cachedImage(for: url("a.jpg")) != nil)
    }

    @Test func differentOptionsAreSeparateCacheEntries() async throws {
        let fake = FakeDecoder()
        let scheduler = DecodeScheduler(costLimit: 1 << 30, decoder: fake.decoder)

        _ = try await scheduler.image(for: url("a.jpg"), options: .fitting(100))
        _ = try await scheduler.image(for: url("a.jpg"), options: .fullResolution)

        #expect(fake.callCount(for: url("a.jpg")) == 2)
        #expect(await scheduler.cachedImage(for: url("a.jpg"), options: .fitting(100)) != nil)
        #expect(await scheduler.cachedImage(for: url("a.jpg"), options: .fitting(200)) == nil)
    }

    @Test func theMemoryOfFailedFilesIsBounded() async throws {
        let fake = FakeDecoder()
        let scheduler = DecodeScheduler(costLimit: 1 << 30, decoder: fake.decoder)

        await scheduler.preload((0..<300).map { url("bad\($0).jpg") })
        try await eventually { fake.calls.count == 300 }
        try await eventually { await scheduler.queuedCount == 0 }

        let remembered = await scheduler.failedCount
        #expect(remembered > 0 && remembered <= 256)
    }

    @Test func aNewModificationTimeWithinTheSameSecondStillInvalidatesTheCache() async throws {
        let folder = try TemporaryFolder()
        try folder.touch("a.jpg", contents: "same size every time")
        let fake = FakeDecoder()
        let scheduler = DecodeScheduler(costLimit: 1 << 30, decoder: fake.decoder)
        let path = folder.file("a.jpg").path

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.1)], ofItemAtPath: path)
        _ = try await scheduler.image(for: folder.file("a.jpg"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.4)], ofItemAtPath: path)
        _ = try await scheduler.image(for: folder.file("a.jpg"))

        #expect(fake.callCount(for: folder.file("a.jpg")) == 2)
    }

    @Test func theReservedSlotScalesWithTheLimit() {
        let reserved = [1, 2, 3, 4, 8].map {
            DecodeScheduler(maxConcurrentDecodes: $0, decoder: FakeDecoder().decoder).maxConcurrentPreloads
        }

        #expect(reserved == [1, 1, 2, 3, 7], "all but one slot, and never fewer than one")
    }

    @Test func withTwoSlotsAVisibleRequestStartsWhileAPreloadRuns() async throws {
        let fake = FakeDecoder(gated: true)
        let scheduler = DecodeScheduler(costLimit: 1 << 30, maxConcurrentDecodes: 2, decoder: fake.decoder)

        await scheduler.preload([url("p1.jpg"), url("p2.jpg"), url("p3.jpg")])
        try await eventually { fake.calls.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.calls.count == 1, "only one preload may run")

        async let visible = scheduler.image(for: url("v.jpg"))
        try await eventually { fake.calls.count == 2 }
        #expect(fake.calls.map(\.lastPathComponent) == ["p1.jpg", "v.jpg"])
        fake.release(4)
        _ = try await visible
    }

    @Test func theCacheBudgetIsFlatAndTheConcurrencyScalesWithTheCores() {
        #expect(DecodeScheduler.defaultCostLimit == 512 << 20)
        #expect(DecodeScheduler.defaultConcurrency(cores: 8) == 4)
        #expect(DecodeScheduler.defaultConcurrency(cores: 3) == 2)
        #expect(DecodeScheduler.defaultConcurrency(cores: 32) == 4, "never more than four decodes at once")
    }
}
