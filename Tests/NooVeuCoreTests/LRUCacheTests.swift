import Testing
@testable import NooVeuCore

@Suite("LRUCache")
struct LRUCacheTests {
    @Test func evictsTheLeastRecentlyUsedEntryFirst() {
        var cache = LRUCache<String, Int>(costLimit: 30)
        cache.insert(1, for: "a", cost: 10)
        cache.insert(2, for: "b", cost: 10)
        cache.insert(3, for: "c", cost: 10)
        _ = cache.value(for: "a")  // "b" is now the oldest

        let evicted = cache.insert(4, for: "d", cost: 10)

        #expect(evicted == ["b"])
        #expect(cache.contains("a") && cache.contains("c") && cache.contains("d"))
        #expect(cache.totalCost == 30)
    }

    @Test func keepsAnOversizedEntryButEvictsEverythingElse() {
        var cache = LRUCache<String, Int>(costLimit: 10)
        cache.insert(1, for: "a", cost: 5)

        cache.insert(2, for: "huge", cost: 50)

        #expect(cache.count == 1)
        #expect(cache.contains("huge"))
        #expect(cache.totalCost == 50)
    }

    @Test func replacingAnEntryUpdatesItsCost() {
        var cache = LRUCache<String, Int>(costLimit: 100)
        cache.insert(1, for: "a", cost: 40)
        cache.insert(2, for: "a", cost: 10)

        #expect(cache.totalCost == 10)
        #expect(cache.value(for: "a") == 2)
    }

    @Test func removalReleasesCost() {
        var cache = LRUCache<String, Int>(costLimit: 100)
        cache.insert(1, for: "a", cost: 40)
        cache.insert(2, for: "b", cost: 20)

        #expect(cache.removeValue(for: "a") == 1)
        #expect(cache.totalCost == 20)
        cache.removeAll()
        #expect(cache.count == 0 && cache.totalCost == 0)
    }

    @Test func aMissReturnsNothingAndAZeroLimitKeepsOnlyTheNewestEntry() {
        var cache = LRUCache<String, Int>(costLimit: 0)

        #expect(cache.value(for: "none") == nil)
        cache.insert(1, for: "a", cost: 5)
        cache.insert(2, for: "b", cost: 5)

        #expect(cache.count == 1 && cache.contains("b"))
    }

    @Test func replacingAnEntryWithABiggerOneEvictsOthers() {
        var cache = LRUCache<String, Int>(costLimit: 30)
        cache.insert(1, for: "a", cost: 10)
        cache.insert(2, for: "b", cost: 10)

        let evicted = cache.insert(3, for: "b", cost: 25)

        #expect(evicted == ["a"])
        #expect(cache.totalCost == 25)
    }
}
