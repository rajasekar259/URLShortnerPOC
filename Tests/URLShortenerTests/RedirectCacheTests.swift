import Foundation
import Testing
@testable import URLShortener

/// Manually advanced monotonic clock so TTL tests don't sleep.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1_000

    var now: TimeInterval { lock.withLock { time } }
    func advance(by seconds: TimeInterval) { lock.withLock { time += seconds } }
}

/// Counts loader invocations.
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct LoadFailure: Error {}

private func makeCache(maxEntries: Int = 100,
                       ttl: TimeInterval = 3_600,
                       negativeTTL: TimeInterval = 30,
                       clock: TestClock = TestClock()) -> RedirectCache {
    RedirectCache(
        configuration: .init(maxEntries: maxEntries, ttl: ttl, negativeTTL: negativeTTL),
        now: { clock.now }
    )
}

/// A loader that returns `url` and records the call.
private func loader(_ url: String?, counter: CallCounter) -> @Sendable () async throws -> String? {
    { await counter.increment(); return url }
}

@Suite("RedirectCache")
struct RedirectCacheTests {
    @Test("A miss loads once, then later lookups are served from memory")
    func missThenHit() async throws {
        let cache = makeCache()
        let calls = CallCounter()

        let first = try await cache.resolve("aaaaaaa", load: loader("https://example.com/", counter: calls))
        let second = try await cache.resolve("aaaaaaa", load: loader("https://example.com/", counter: calls))

        #expect(first == "https://example.com/")
        #expect(second == "https://example.com/")
        #expect(await calls.count == 1)
        let stats = await cache.stats
        #expect(stats.misses == 1)
        #expect(stats.hits == 1)
    }

    @Test("Unknown codes are negatively cached")
    func negativeCache() async throws {
        let cache = makeCache()
        let calls = CallCounter()

        #expect(try await cache.resolve("missing", load: loader(nil, counter: calls)) == nil)
        #expect(try await cache.resolve("missing", load: loader(nil, counter: calls)) == nil)

        #expect(await calls.count == 1)
        #expect(await cache.stats.negativeHits == 1)
    }

    @Test("A negative entry expires after the negative TTL, so a code created later is found")
    func negativeExpiry() async throws {
        let clock = TestClock()
        let cache = makeCache(negativeTTL: 30, clock: clock)
        let calls = CallCounter()

        #expect(try await cache.resolve("later", load: loader(nil, counter: calls)) == nil)
        clock.advance(by: 29)
        #expect(try await cache.resolve("later", load: loader("https://example.com/", counter: calls)) == nil)
        clock.advance(by: 2)
        #expect(try await cache.resolve("later", load: loader("https://example.com/", counter: calls)) == "https://example.com/")
        #expect(await calls.count == 2)
    }

    @Test("Entries expire after the TTL")
    func ttlExpiry() async throws {
        let clock = TestClock()
        let cache = makeCache(ttl: 100, clock: clock)
        let calls = CallCounter()

        _ = try await cache.resolve("code001", load: loader("https://a.test/", counter: calls))
        clock.advance(by: 99)
        _ = try await cache.resolve("code001", load: loader("https://a.test/", counter: calls))
        #expect(await calls.count == 1)

        clock.advance(by: 2)
        _ = try await cache.resolve("code001", load: loader("https://a.test/", counter: calls))
        #expect(await calls.count == 2)
    }

    @Test("The least recently used entry is evicted first")
    func lruEviction() async throws {
        let cache = makeCache(maxEntries: 2)
        let calls = CallCounter()

        _ = try await cache.resolve("a", load: loader("https://a.test/", counter: calls))
        _ = try await cache.resolve("b", load: loader("https://b.test/", counter: calls))
        _ = try await cache.resolve("a", load: loader("https://a.test/", counter: calls))   // touch a, so b is oldest
        _ = try await cache.resolve("c", load: loader("https://c.test/", counter: calls))   // evicts b
        #expect(await calls.count == 3)
        #expect(await cache.stats.evictions == 1)

        _ = try await cache.resolve("a", load: loader("https://a.test/", counter: calls))   // still cached
        _ = try await cache.resolve("c", load: loader("https://c.test/", counter: calls))   // still cached
        #expect(await calls.count == 3)

        _ = try await cache.resolve("b", load: loader("https://b.test/", counter: calls))   // was evicted
        #expect(await calls.count == 4)
    }

    @Test("The cache never grows beyond maxEntries")
    func bounded() async throws {
        let cache = makeCache(maxEntries: 50)
        for i in 0..<500 {
            await cache.store("code\(i)", longURL: "https://example.com/\(i)")
        }
        #expect(await cache.count == 50)
    }

    @Test("Concurrent misses for one code share a single load")
    func singleFlight() async throws {
        let cache = makeCache()
        let calls = CallCounter()
        let slowLoad: @Sendable () async throws -> String? = {
            await calls.increment()
            try await Task.sleep(for: .milliseconds(100))
            return "https://example.com/"
        }

        let results = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<100 { group.addTask { try await cache.resolve("shared1", load: slowLoad) } }
            return try await group.reduce(into: [String?]()) { $0.append($1) }
        }

        #expect(results.count == 100)
        #expect(results.allSatisfy { $0 == "https://example.com/" })
        #expect(await calls.count == 1)
        #expect(await cache.stats.coalesced == 99)
    }

    @Test("store() is a write-through and replaces a negative entry")
    func storeWriteThrough() async throws {
        let cache = makeCache()
        let calls = CallCounter()

        #expect(try await cache.resolve("fresh01", load: loader(nil, counter: calls)) == nil)
        await cache.store("fresh01", longURL: "https://example.com/")

        let result = try await cache.resolve("fresh01", load: {
            Issue.record("loader must not run after store()")
            return nil
        })
        #expect(result == "https://example.com/")
    }

    @Test("invalidate() forgets the code")
    func invalidate() async throws {
        let cache = makeCache()
        let calls = CallCounter()

        _ = try await cache.resolve("gone001", load: loader("https://example.com/", counter: calls))
        await cache.invalidate("gone001")
        let result = try await cache.resolve("gone001", load: loader(nil, counter: calls))

        #expect(result == nil)
        #expect(await calls.count == 2)
    }

    @Test("A load that was in flight during invalidate() does not resurrect the entry")
    func invalidateDuringLoad() async throws {
        let cache = makeCache()
        let started = CallCounter()
        let staleLoad: @Sendable () async throws -> String? = {
            await started.increment()
            try await Task.sleep(for: .milliseconds(150))
            return "https://stale.test/"
        }

        async let stale = cache.resolve("race001", load: staleLoad)
        while await started.count == 0 { await Task.yield() }   // wait until the load is running
        await cache.invalidate("race001")
        _ = try await stale

        let fresh = try await cache.resolve("race001", load: { "https://fresh.test/" })
        #expect(fresh == "https://fresh.test/")
    }

    @Test("Loader errors propagate to every waiter and are not cached")
    func loaderErrors() async throws {
        let cache = makeCache()
        let failing: @Sendable () async throws -> String? = {
            try await Task.sleep(for: .milliseconds(50))
            throw LoadFailure()
        }

        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    do { _ = try await cache.resolve("boom001", load: failing); return false }
                    catch is LoadFailure { return true }
                    catch { return false }
                }
            }
            return await group.reduce(into: 0) { $0 += $1 ? 1 : 0 }
        }
        #expect(failures == 10)

        let recovered = try await cache.resolve("boom001", load: { "https://example.com/" })
        #expect(recovered == "https://example.com/")
    }

    @Test("Many concurrent lookups across many codes stay consistent")
    func concurrentMixedAccess() async throws {
        let cache = makeCache(maxEntries: 64)
        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<2_000 {
                group.addTask {
                    let code = "code\(i % 200)"
                    let url = try await cache.resolve(code, load: { "https://example.com/\(code)" })
                    return url == "https://example.com/\(code)"
                }
            }
            return try await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(results.allSatisfy { $0 })
        #expect(await cache.count <= 64)
    }
}
