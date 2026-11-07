import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import NooVeuCore

/// Holds named tile decodes until a test releases them.
actor TileGates {
    private var held: Set<TileID> = []
    private var waiting: [TileID: [CheckedContinuation<Void, Never>]] = [:]

    func hold(_ ids: TileID...) { held.formUnion(ids) }
    func holdAll(_ ids: [TileID]) { held.formUnion(ids) }

    func wait(_ id: TileID) async {
        guard held.contains(id) else { return }
        await withCheckedContinuation { waiting[id, default: []].append($0) }
    }

    func release(_ ids: TileID...) {
        for id in ids {
            held.remove(id)
            for continuation in waiting.removeValue(forKey: id) ?? [] { continuation.resume() }
        }
    }

    func releaseAll() {
        held.removeAll()
        for continuations in waiting.values { for continuation in continuations { continuation.resume() } }
        waiting.removeAll()
    }
}

/// A tile source that renders nothing real: a tile is a small solid bitmap, after a gate.
final class FakeTileSource: TileSource, Sendable {
    let grid: TileGrid
    var trueSize: PixelSize { grid.sourceSize }
    let detailFactor: Double = 1
    let retainedBytes = 0
    let gates = TileGates()
    private let state = Mutex(State())

    struct State {
        var started: [TileID] = []
        var active = 0
        var peak = 0
        var failing: Set<TileID> = []
        var failEverything = false
    }

    init(grid: TileGrid = TileGrid(sourceSize: PixelSize(width: 1000, height: 700), tileSize: 256)) {
        self.grid = grid
    }

    var started: [TileID] { state.withLock { $0.started } }
    var peakConcurrency: Int { state.withLock { $0.peak } }
    func fail(_ ids: TileID...) { state.withLock { $0.failing.formUnion(ids) } }
    func failEverything() { state.withLock { $0.failEverything = true } }
    func stopFailing() { state.withLock { $0.failing.removeAll(); $0.failEverything = false } }
    func count(_ id: TileID) -> Int { started.filter { $0 == id }.count }

    func tile(_ id: TileID) async throws -> TileBitmap {
        state.withLock {
            $0.started.append(id)
            $0.active += 1
            $0.peak = max($0.peak, $0.active)
        }
        await gates.wait(id)
        let fails = state.withLock { s -> Bool in
            s.active -= 1
            return s.failEverything || s.failing.contains(id)
        }
        if fails { throw TileError.renderFailed(id) }
        let padded = grid.paddedRect(of: id)
        let context = CGContext(data: nil, width: padded.width, height: padded.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: TileBitmapLayout.bitmapInfo)!
        return TileBitmap(id: id, image: context.makeImage()!, paddedRect: padded)
    }
}

/// Collects what a loader delivers.
final class Received: Sendable {
    private let ids = Mutex<[TileID]>([])
    var all: [TileID] { ids.withLock { $0 } }
    func add(_ id: TileID) { ids.withLock { $0.append(id) } }
    func count(_ id: TileID) -> Int { all.filter { $0 == id }.count }
}

final class Switch: Sendable {
    private let flag = Mutex(false)
    func set() { flag.withLock { $0 = true } }
    var isSet: Bool { flag.withLock { $0 } }
}

private func id(_ column: Int, _ row: Int = 0, level: Int = 0) -> TileID { TileID(level: level, column: column, row: row) }

/// Polls until `condition` holds (2 s at most), recording a failure otherwise.
private func eventually(_ what: String, _ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<400 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for: \(what)")
}

@Suite("TileLoader", .timeLimit(.minutes(1)))
struct TileLoaderTests {
    private func makeLoader(_ source: FakeTileSource, concurrent: Int = 3, cacheBytes: Int = 128 << 20) -> (TileLoader, Received, Task<Void, Never>) {
        let loader = TileLoader(source: source, cacheBytes: cacheBytes, maxConcurrentDecodes: concurrent)
        let received = Received()
        let stream = loader.tiles
        let consumer = Task { for await tile in stream { received.add(tile.id) } }
        return (loader, received, consumer)
    }

    // MARK: Loading

    @Test func wantedTilesAreDecodedAndDelivered() async throws {
        let source = FakeTileSource()
        let (loader, received, _) = makeLoader(source)

        await loader.want([id(0), id(1), id(2)])
        try await eventually("three tiles") { received.all.count == 3 }

        #expect(Set(received.all) == [id(0), id(1), id(2)])
        #expect(await loader.statistics.decodesStarted == 3)
    }

    @Test func tilesStartInTheOrderGivenAndNoMoreThanTheLimitRunAtOnce() async throws {
        let source = FakeTileSource()
        // Six tiles that exist: the grid has four columns and three rows.
        let six = [id(0), id(1), id(2), id(3), id(0, 1), id(1, 1)]
        await source.gates.holdAll(six)
        let (loader, _, _) = makeLoader(source, concurrent: 2)

        await loader.want(six)
        try await eventually("two running") { source.started.count == 2 }
        try await Task.sleep(for: .milliseconds(40))

        // Two run at once, so the order they log in within a pair is not fixed: what is fixed is which
        // pair comes first, and that nothing starts beyond the limit.
        #expect(Set(source.started) == [id(0), id(1)], "the first two in the list, and no more yet")
        await source.gates.releaseAll()
        try await eventually("all started") { source.started.count == 6 }
        #expect(Set(source.started[0..<2]) == [id(0), id(1)])
        #expect(Set(source.started[2..<4]) == [id(2), id(3)])
        #expect(Set(source.started[4..<6]) == [id(0, 1), id(1, 1)])
        #expect(source.peakConcurrency <= 2)
    }

    @Test func aLimitOfZeroMeansOne() async {
        let loader = TileLoader(source: FakeTileSource(), maxConcurrentDecodes: 0)

        #expect(loader.maxConcurrentDecodes == 1)
    }

    @Test func aTileNoLongerWantedIsDroppedFromTheQueueUndecoded() async throws {
        let source = FakeTileSource()
        let five = [id(0), id(1), id(2), id(3), id(0, 1)]
        await source.gates.holdAll(five)
        let (loader, _, _) = makeLoader(source, concurrent: 1)

        await loader.want(five)  // 0 runs; the other four wait
        try await eventually("0 running") { source.started == [id(0)] }
        await loader.want([id(0, 1)])  // the view moved: only the last matters now
        await source.gates.releaseAll()
        try await eventually("the wanted one decoded") { source.count(id(0, 1)) == 1 }
        try await Task.sleep(for: .milliseconds(40))

        #expect(source.started == [id(0), id(0, 1)], "1, 2 and 3 were never decoded")
        #expect(await loader.statistics.droppedQueued == 3, "exactly the three that were queued and not wanted")
    }

    @Test func theQueueIsReorderedWhenTheWantChanges() async throws {
        let source = FakeTileSource()
        await source.gates.holdAll([id(0)])
        let (loader, _, _) = makeLoader(source, concurrent: 1)

        await loader.want([id(0), id(1), id(2), id(3)])
        try await eventually("0 running") { source.started == [id(0)] }
        await loader.want([id(3), id(2), id(1)])  // reversed
        await source.gates.releaseAll()
        try await eventually("all four") { source.started.count == 4 }

        #expect(source.started == [id(0), id(3), id(2), id(1)])
    }

    @Test func aTileAskedForAgainWhileRunningOrQueuedIsNotDecodedTwice() async throws {
        let source = FakeTileSource()
        await source.gates.holdAll([id(0), id(1)])
        let (loader, _, _) = makeLoader(source, concurrent: 1)

        await loader.want([id(0), id(1)])
        try await eventually("0 running") { source.started == [id(0)] }
        await loader.want([id(0), id(1)])
        await loader.want([id(1), id(0), id(0)])
        await source.gates.releaseAll()
        try await eventually("both done") { await loader.cachedCount == 2 }

        #expect(source.count(id(0)) == 1 && source.count(id(1)) == 1)
    }

    @Test func theSameTileTwiceInOneListIsDecodedOnce() async throws {
        let source = FakeTileSource()
        let (loader, received, _) = makeLoader(source, concurrent: 3)

        await loader.want([id(0), id(0), id(0)])
        try await eventually("delivered") { received.count(id(0)) >= 1 }
        try await Task.sleep(for: .milliseconds(30))

        #expect(source.count(id(0)) == 1)
        #expect(received.count(id(0)) == 1)
    }

    @Test func tilesOutsideTheGridAreIgnored() async throws {
        let source = FakeTileSource()
        let (loader, received, _) = makeLoader(source)

        await loader.want([id(99, 99), id(0, level: 7), id(0)])
        try await eventually("the valid one") { received.count(id(0)) == 1 }

        #expect(source.started == [id(0)])
    }

    // MARK: Caching and what the view already holds

    @Test func aCachedTileTheViewLostIsDeliveredAgainWithoutDecoding() async throws {
        let source = FakeTileSource()
        let (loader, received, _) = makeLoader(source)
        await loader.want([id(0)])
        try await eventually("first delivery") { received.count(id(0)) == 1 }

        await loader.want([id(0)])  // the GPU evicted it and the view needs it again
        try await eventually("second delivery") { received.count(id(0)) == 2 }

        #expect(source.count(id(0)) == 1)
        #expect(await loader.statistics.cacheHits == 1)
    }

    @Test func aTileTheViewAlreadyHoldsIsNeitherDeliveredNorDecoded() async throws {
        let source = FakeTileSource()
        let (loader, received, _) = makeLoader(source)
        await loader.want([id(0), id(1)])
        try await eventually("both delivered") { received.all.count == 2 }

        // A view asking every frame, holding both: no upload storm.
        for _ in 0..<200 { await loader.want([id(0), id(1)], alreadyHeld: [id(0), id(1)]) }
        // ...and one that holds a tile it never got from the loader must not have it decoded either.
        await loader.want([id(2)], alreadyHeld: [id(2)])
        try await Task.sleep(for: .milliseconds(40))

        #expect(received.all.count == 2, "nothing delivered again")
        #expect(source.started.count == 2, "nothing decoded for tiles already held")
        #expect(await loader.statistics.cacheHits == 0)
    }

    @Test func aTileThatFinishesAfterTheViewMovedOnIsCachedButNotDelivered() async throws {
        let source = FakeTileSource()
        await source.gates.hold(id(0))
        let (loader, received, _) = makeLoader(source)

        await loader.want([id(0)])
        try await eventually("0 running") { source.started == [id(0)] }
        await loader.want([id(1)])  // the view moved away from 0
        await source.gates.release(id(0))
        try await eventually("1 delivered") { received.count(id(1)) == 1 }
        try await eventually("0 cached") { await loader.cachedCount == 2 }

        #expect(received.count(id(0)) == 0, "out of view: no point uploading it")
        await loader.want([id(0)])  // back again
        try await eventually("0 delivered from cache") { received.count(id(0)) == 1 }
        #expect(source.count(id(0)) == 1, "and it was not decoded again")
    }

    @Test func theCacheIsByteLimitedAndEvictsTheOldest() async throws {
        let source = FakeTileSource()
        // A full 256 px tile is about 260 KB: room for two.
        let (loader, received, _) = makeLoader(source, concurrent: 1, cacheBytes: 600_000)

        await loader.want([id(1, 1)])
        try await eventually("first") { received.count(id(1, 1)) == 1 }
        await loader.want([id(1, 0)])
        try await eventually("second") { received.count(id(1, 0)) == 1 }
        await loader.want([id(0, 1)])
        try await eventually("third") { received.count(id(0, 1)) == 1 }

        #expect(await loader.cachedCount == 2)
        await loader.want([id(1, 1)])  // the oldest was evicted: it must be decoded again
        try await eventually("evicted tile decoded again") { source.count(id(1, 1)) == 2 }
    }

    // MARK: Failures

    @Test func aFailedTileIsNotRetriedUntilInvalidated() async throws {
        let source = FakeTileSource()
        source.fail(id(0))
        let (loader, received, _) = makeLoader(source)

        await loader.want([id(0), id(1)])
        try await eventually("1 delivered") { received.count(id(1)) == 1 }
        try await eventually("0 failed") { await loader.statistics.failures == 1 }
        await loader.want([id(0), id(1)])  // a view asking every frame
        await loader.want([id(0), id(1)])
        try await Task.sleep(for: .milliseconds(40))

        #expect(source.count(id(0)) == 1, "no retry loop")
        #expect(received.count(id(0)) == 0)
        #expect(await loader.state(of: id(0)) == .failed)
        #expect(await loader.failedTiles == [id(0)])

        source.stopFailing()
        await loader.invalidate()  // also wants the same tiles again
        try await eventually("0 delivered after invalidate") { received.count(id(0)) >= 1 }
        #expect(source.count(id(0)) == 2)
    }

    @Test func noMatterHowManyTilesFailNoneIsRetriedByAskingAgain() async throws {
        // 40000×20000 in 512 px tiles: 79×40 tiles at level 0, far more than any fixed memory of failures.
        let source = FakeTileSource(grid: TileGrid(sourceSize: PixelSize(width: 40_000, height: 20_000), tileSize: 512))
        source.failEverything()
        let (loader, _, _) = makeLoader(source, concurrent: 8)
        let many = (0..<400).map { id($0 % 79, $0 / 79) }

        await loader.want(many)
        try await eventually("all failed once") { await loader.statistics.failures == 400 }
        for _ in 0..<3 {
            await loader.want(many)
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await loader.statistics.decodesStarted == 400, "not one of them was retried")
    }

    // MARK: State and invalidation

    @Test func theStateOfATileFollowsItsLife() async throws {
        let source = FakeTileSource()
        await source.gates.holdAll([id(0), id(1)])
        let (loader, _, _) = makeLoader(source, concurrent: 1)
        #expect(await loader.state(of: id(0)) == .unknown)

        await loader.want([id(0), id(1)])
        try await eventually("0 running") { source.started == [id(0)] }
        #expect(await loader.state(of: id(0)) == .running)
        #expect(await loader.state(of: id(1)) == .queued)

        await source.gates.releaseAll()
        try await eventually("both cached") { await loader.cachedCount == 2 }
        #expect(await loader.state(of: id(0)) == .cached)
    }

    @Test func invalidatingDiscardsAStaleDecodeAndLoadsTheTileAgain() async throws {
        let source = FakeTileSource()
        await source.gates.hold(id(0))
        let (loader, received, _) = makeLoader(source)
        await loader.want([id(0)])
        try await eventually("0 running") { source.started == [id(0)] }

        await loader.invalidate()  // the file changed while 0 was being decoded
        try await eventually("0 started again") { source.count(id(0)) == 2 }
        await source.gates.releaseAll()
        try await eventually("delivered") { received.count(id(0)) >= 1 }
        try await Task.sleep(for: .milliseconds(30))

        #expect(received.count(id(0)) == 1, "only the new decode's result: the stale one was discarded")
        #expect(await loader.cachedCount == 1)
    }

    @Test func invalidatingForgetsTheCache() async throws {
        let source = FakeTileSource()
        let (loader, received, _) = makeLoader(source)
        await loader.want([id(0)])
        try await eventually("delivered") { received.count(id(0)) == 1 }

        await loader.invalidate()
        try await eventually("decoded again") { source.count(id(0)) == 2 }
    }

    // MARK: Closing

    @Test func closingEndsTheStreamStopsLoadingAndFreesTheCache() async throws {
        let source = FakeTileSource()
        let (loader, received, consumer) = makeLoader(source, concurrent: 1)
        await loader.want([id(2)])  // something in the cache to free
        try await eventually("2 cached") { await loader.cachedCount == 1 }
        let deliveredBefore = received.all.count
        await source.gates.holdAll([id(0), id(1)])
        await loader.want([id(0), id(1)])
        try await eventually("0 running") { source.count(id(0)) == 1 }

        await loader.close()
        await source.gates.releaseAll()
        await consumer.value  // the stream ended, so the consumer returns
        try await Task.sleep(for: .milliseconds(100))  // long enough for a wrongly kept queue to start 1

        #expect(received.all.count == deliveredBefore, "nothing is delivered after closing")
        #expect(source.count(id(1)) == 0, "queued work was dropped")
        #expect(await loader.cachedCount == 0, "the cache is freed, and the finishing decode is not added to it")
        await loader.want([id(3)])  // ignored
        try await Task.sleep(for: .milliseconds(30))
        #expect(source.count(id(3)) == 0)
    }

    @Test func droppingTheLoaderEndsTheStream() async throws {
        let source = FakeTileSource()
        var loader: TileLoader? = TileLoader(source: source)
        let stream = loader!.tiles
        let ended = Switch()
        let consumer = Task {
            for await _ in stream {}
            ended.set()
        }
        weak var weakLoader = loader

        loader = nil  // dropped without close()
        try await eventually("the stream to end") { ended.isSet }

        #expect(weakLoader == nil)
        _ = consumer
    }
}
