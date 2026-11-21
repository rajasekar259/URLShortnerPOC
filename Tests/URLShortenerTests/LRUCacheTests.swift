import Testing
@testable import URLShortener

@Suite("LRUCache")
struct LRUCacheTests {
    @Test("Stores and returns values")
    func basic() {
        var cache = LRUCache<String, Int>(capacity: 3)
        #expect(cache.isEmpty)
        cache.setValue(1, for: "a")
        cache.setValue(2, for: "b")

        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "b") == 2)
        #expect(cache.value(for: "c") == nil)
        #expect(cache.count == 2)
        #expect(cache.contains("a"))
        #expect(!cache.contains("c"))
    }

    @Test("Evicts the least recently used entry and reports it")
    func evictsOldest() {
        var cache = LRUCache<String, Int>(capacity: 2)
        #expect(cache.setValue(1, for: "a") == nil)
        #expect(cache.setValue(2, for: "b") == nil)

        let evicted = cache.setValue(3, for: "c")
        #expect(evicted?.key == "a")
        #expect(evicted?.value == 1)
        #expect(cache.keysByRecency == ["c", "b"])
        #expect(cache.count == 2)
    }

    @Test("Reading marks an entry as most recently used")
    func readRefreshesRecency() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, for: "a")
        cache.setValue(2, for: "b")
        _ = cache.value(for: "a")           // a is now newer than b

        let evicted = cache.setValue(3, for: "c")
        #expect(evicted?.key == "b")
        #expect(cache.keysByRecency == ["c", "a"])
    }

    @Test("peekValue does not change recency")
    func peekKeepsOrder() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, for: "a")
        cache.setValue(2, for: "b")
        #expect(cache.peekValue(for: "a") == 1)

        let evicted = cache.setValue(3, for: "c")
        #expect(evicted?.key == "a")        // still the oldest despite the peek
    }

    @Test("Updating an existing key replaces the value, refreshes recency and never evicts")
    func updateInPlace() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, for: "a")
        cache.setValue(2, for: "b")

        #expect(cache.setValue(10, for: "a") == nil)
        #expect(cache.count == 2)
        #expect(cache.peekValue(for: "a") == 10)
        #expect(cache.keysByRecency == ["a", "b"])
    }

    @Test("removeValue returns the value and frees the slot")
    func remove() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, for: "a")
        cache.setValue(2, for: "b")

        #expect(cache.removeValue(for: "a") == 1)
        #expect(cache.removeValue(for: "a") == nil)
        #expect(cache.count == 1)

        // The freed slot is reusable without evicting "b".
        #expect(cache.setValue(3, for: "c") == nil)
        #expect(cache.keysByRecency == ["c", "b"])
    }

    @Test("removeLeastRecentlyUsed pops in age order")
    func popOldest() {
        var cache = LRUCache<String, Int>(capacity: 3)
        cache.setValue(1, for: "a")
        cache.setValue(2, for: "b")
        cache.setValue(3, for: "c")

        #expect(cache.removeLeastRecentlyUsed()?.key == "a")
        #expect(cache.removeLeastRecentlyUsed()?.key == "b")
        #expect(cache.removeLeastRecentlyUsed()?.key == "c")
        #expect(cache.removeLeastRecentlyUsed() == nil)
        #expect(cache.isEmpty)
    }

    @Test("removeAll empties the cache and it stays usable")
    func clear() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, for: "a")
        cache.setValue(2, for: "b")
        cache.removeAll()

        #expect(cache.isEmpty)
        #expect(cache.keysByRecency.isEmpty)
        cache.setValue(3, for: "c")
        #expect(cache.value(for: "c") == 3)
    }

    @Test("A capacity of one keeps only the latest entry")
    func capacityOne() {
        var cache = LRUCache<Int, String>(capacity: 1)
        cache.setValue("a", for: 1)
        #expect(cache.setValue("b", for: 2)?.key == 1)
        #expect(cache.value(for: 1) == nil)
        #expect(cache.value(for: 2) == "b")
    }

    @Test("Copies are independent (value semantics)")
    func valueSemantics() {
        var original = LRUCache<String, Int>(capacity: 2)
        original.setValue(1, for: "a")
        var copy = original

        copy.setValue(2, for: "b")
        copy.removeValue(for: "a")

        #expect(original.keysByRecency == ["a"])
        #expect(copy.keysByRecency == ["b"])
    }

    @Test("Behaves like a reference model under random operations")
    func randomOperationsMatchModel() {
        struct SeededGenerator: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return state
            }
        }

        let capacity = 8
        var cache = LRUCache<Int, Int>(capacity: capacity)
        var model: [(key: Int, value: Int)] = []        // index 0 = most recently used
        var rng = SeededGenerator(state: 42)

        for step in 0..<20_000 {
            let key = Int.random(in: 0..<20, using: &rng)
            switch Int.random(in: 0..<4, using: &rng) {
            case 0, 1:                                   // set
                let evicted = cache.setValue(step, for: key)
                if let existing = model.firstIndex(where: { $0.key == key }) {
                    model.remove(at: existing)
                    model.insert((key, step), at: 0)
                    #expect(evicted == nil)
                } else {
                    model.insert((key, step), at: 0)
                    if model.count > capacity {
                        let last = model.removeLast()
                        #expect(evicted?.key == last.key)
                        #expect(evicted?.value == last.value)
                    } else {
                        #expect(evicted == nil)
                    }
                }
            case 2:                                      // get (refreshes recency)
                let value = cache.value(for: key)
                if let existing = model.firstIndex(where: { $0.key == key }) {
                    let entry = model.remove(at: existing)
                    model.insert(entry, at: 0)
                    #expect(value == entry.value)
                } else {
                    #expect(value == nil)
                }
            default:                                     // remove
                let removed = cache.removeValue(for: key)
                if let existing = model.firstIndex(where: { $0.key == key }) {
                    #expect(removed == model.remove(at: existing).value)
                } else {
                    #expect(removed == nil)
                }
            }
            #expect(cache.count == model.count)
        }
        #expect(cache.keysByRecency == model.map(\.key))
    }
}
