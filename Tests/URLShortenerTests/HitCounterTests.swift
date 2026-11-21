import Foundation
import Testing
@testable import URLShortener

/// In-memory store that records every batch, and can be told to fail or to be slow.
private actor RecordingHitStore: HitStore {
    struct Failure: Error {}

    private(set) var batches: [[String: Int]] = []
    private(set) var started = 0
    private var failuresRemaining: Int
    private let delay: Duration

    init(failures: Int = 0, delay: Duration = .zero) {
        self.failuresRemaining = failures
        self.delay = delay
    }

    func apply(_ increments: [String: Int]) async throws {
        started += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw Failure()
        }
        batches.append(increments)
    }

    var totals: [String: Int] {
        batches.reduce(into: [:]) { totals, batch in
            for (code, count) in batch { totals[code, default: 0] += count }
        }
    }
}

private func makeCounter(_ store: RecordingHitStore,
                         flushInterval: TimeInterval = 3_600,
                         maxPendingCodes: Int = 10_000) -> HitCounter {
    HitCounter(store: store, configuration: .init(flushInterval: flushInterval, maxPendingCodes: maxPendingCodes))
}

/// Polls until `condition` holds or the timeout passes.
private func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Suite("HitCounter")
struct HitCounterTests {
    @Test("Hits are aggregated per code and written as one batch")
    func aggregatesIntoOneBatch() async throws {
        let store = RecordingHitStore()
        let counter = makeCounter(store)

        for _ in 0..<3 { await counter.record("aaaaaaa") }
        for _ in 0..<2 { await counter.record("bbbbbbb") }
        try await counter.flush()

        #expect(await store.batches == [["aaaaaaa": 3, "bbbbbbb": 2]])
        #expect(await counter.unflushedCount(for: "aaaaaaa") == 0)
    }

    @Test("record() never writes to the store")
    func recordDoesNotFlush() async {
        let store = RecordingHitStore()
        let counter = makeCounter(store)

        for _ in 0..<500 { await counter.record("aaaaaaa") }

        #expect(await store.started == 0)
        #expect(await counter.unflushedCount(for: "aaaaaaa") == 500)
    }

    @Test("Flushing with nothing pending does not call the store")
    func emptyFlush() async throws {
        let store = RecordingHitStore()
        let counter = makeCounter(store)
        try await counter.flush()
        #expect(await store.started == 0)
    }

    @Test("1,000 concurrent hits add up to exactly 1,000")
    func concurrentRecords() async throws {
        let store = RecordingHitStore()
        let counter = makeCounter(store)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<1_000 {
                group.addTask { await counter.record(i.isMultiple(of: 2) ? "even000" : "odd0000") }
            }
        }
        try await counter.flush()

        let totals = await store.totals
        #expect(totals["even000"] == 500)
        #expect(totals["odd0000"] == 500)
    }

    @Test("A failed flush keeps its counts and the next flush writes them once")
    func failedFlushRetries() async throws {
        let store = RecordingHitStore(failures: 1)
        let counter = makeCounter(store)

        for _ in 0..<5 { await counter.record("aaaaaaa") }
        await #expect(throws: RecordingHitStore.Failure.self) { try await counter.flush() }
        #expect(await counter.unflushedCount(for: "aaaaaaa") == 5)

        await counter.record("aaaaaaa")                       // hits keep arriving between attempts
        try await counter.flush()

        #expect(await store.totals == ["aaaaaaa": 6])         // nothing lost, nothing counted twice
        #expect(await counter.unflushedCount(for: "aaaaaaa") == 0)
    }

    @Test("unflushedCount includes hits that are being written")
    func countsInFlight() async throws {
        let store = RecordingHitStore(delay: .milliseconds(200))
        let counter = makeCounter(store)
        for _ in 0..<4 { await counter.record("aaaaaaa") }

        async let flushing: Void = counter.flush()
        #expect(await eventually { await store.started == 1 })    // the write has begun
        await counter.record("aaaaaaa")                           // one more arrives mid-write
        #expect(await counter.unflushedCount(for: "aaaaaaa") == 5)

        try await flushing
        #expect(await counter.unflushedCount(for: "aaaaaaa") == 1)
    }

    @Test("Hits recorded during a flush are not lost")
    func recordsDuringFlush() async throws {
        let store = RecordingHitStore(delay: .milliseconds(100))
        let counter = makeCounter(store)
        for _ in 0..<10 { await counter.record("aaaaaaa") }

        async let flushing: Void = counter.flush()
        #expect(await eventually { await store.started == 1 })
        for _ in 0..<7 { await counter.record("aaaaaaa") }
        try await flushing
        try await counter.flush()

        #expect(await store.totals == ["aaaaaaa": 17])
    }

    @Test("Concurrent flush calls never write the same hits twice")
    func concurrentFlushes() async throws {
        let store = RecordingHitStore(delay: .milliseconds(20))
        let counter = makeCounter(store)
        for _ in 0..<200 { await counter.record("aaaaaaa") }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { try await counter.flush() } }
            try await group.waitForAll()
        }

        #expect(await store.totals == ["aaaaaaa": 200])
    }

    @Test("Reaching maxPendingCodes triggers a flush without waiting for the timer")
    func flushesWhenManyCodesPending() async {
        let store = RecordingHitStore()
        let counter = makeCounter(store, maxPendingCodes: 5)

        for i in 0..<5 { await counter.record("code\(i)") }

        #expect(await eventually { await store.totals.count == 5 })
    }

    @Test("The periodic timer flushes on its own")
    func periodicFlush() async {
        let store = RecordingHitStore()
        let counter = makeCounter(store, flushInterval: 0.05)
        await counter.start()
        await counter.record("aaaaaaa")

        #expect(await eventually { await store.totals["aaaaaaa"] == 1 })
        await counter.shutdown()
    }

    @Test("shutdown() flushes what is still pending")
    func shutdownFlushes() async {
        let store = RecordingHitStore()
        let counter = makeCounter(store)          // timer far in the future, so only shutdown can flush
        await counter.start()
        for _ in 0..<9 { await counter.record("aaaaaaa") }

        await counter.shutdown()

        #expect(await store.totals == ["aaaaaaa": 9])
    }

    @Test("shutdown() survives a failing store")
    func shutdownWithFailingStore() async {
        let store = RecordingHitStore(failures: 1)
        let counter = makeCounter(store)
        await counter.record("aaaaaaa")

        await counter.shutdown()                  // logs the loss, must not crash or hang

        #expect(await store.totals.isEmpty)
    }
}
