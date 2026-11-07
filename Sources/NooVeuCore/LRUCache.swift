/// A least-recently-used cache with a total cost limit.
///
/// Not thread-safe: own it from a single actor. Eviction scans all entries, which is
/// cheap at the sizes NooVeu uses (tens of decoded images, not thousands).
public struct LRUCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var lastUse: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    public let costLimit: Int
    public private(set) var totalCost = 0

    public init(costLimit: Int) {
        self.costLimit = costLimit
    }

    public var count: Int { entries.count }

    public func contains(_ key: Key) -> Bool {
        entries[key] != nil
    }

    /// Returns the value and marks it as just used.
    public mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.lastUse = clock
        entries[key] = entry
        return entry.value
    }

    /// Inserts or replaces a value, then evicts the least recently used entries until the
    /// total cost fits. The entry just inserted is never evicted, even if it alone is over
    /// the limit: it is the image on screen.
    @discardableResult
    public mutating func insert(_ value: Value, for key: Key, cost: Int) -> [Key] {
        if let old = entries[key] {
            totalCost -= old.cost
        }
        clock += 1
        let cost = max(cost, 0)
        entries[key] = Entry(value: value, cost: cost, lastUse: clock)
        totalCost += cost

        var evicted: [Key] = []
        while totalCost > costLimit, let victim = leastRecentlyUsed(excluding: key) {
            removeValue(for: victim)
            evicted.append(victim)
        }
        return evicted
    }

    @discardableResult
    public mutating func removeValue(for key: Key) -> Value? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        totalCost -= entry.cost
        return entry.value
    }

    public mutating func removeAll() {
        entries.removeAll()
        totalCost = 0
    }

    private func leastRecentlyUsed(excluding protected: Key) -> Key? {
        var oldest: (key: Key, lastUse: UInt64)?
        for (key, entry) in entries where key != protected {
            if oldest == nil || entry.lastUse < oldest!.lastUse {
                oldest = (key, entry.lastUse)
            }
        }
        return oldest?.key
    }
}
