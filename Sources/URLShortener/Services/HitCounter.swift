//
//  HitCounter.swift
//  URLShortener
//

import Foundation
import Logging
import Vapor

/// Where aggregated hit counts are persisted.
protocol HitStore: Sendable {
    /// Adds each count to the stored total for its code. Must be additive, so concurrent or repeated
    /// calls (and several app instances) can never overwrite one another.
    func apply(_ increments: [String: Int]) async throws
}

/// Counts redirect hits in memory and writes them to the store in batches, so a redirect never
/// needs a database write.
///
/// - `record(_:)` only bumps an in-memory counter.
/// - Counts are flushed every `flushInterval` seconds, or sooner once `maxPendingCodes` distinct
///   codes are waiting.
/// - A failed flush puts its counts back and they are retried with the next flush.
/// - `shutdown()` stops the timer and flushes what is left. A hard crash can lose up to one
///   flush interval of counts; that trade-off was accepted for the redirect speed-up.
actor HitCounter {
    struct Configuration: Sendable {
        var flushInterval: TimeInterval = 5
        var maxPendingCodes = 10_000
    }

    private let store: any HitStore
    private let configuration: Configuration
    private let logger: Logger

    private var pending: [String: Int] = [:]
    /// Counts handed to the store whose write has not finished yet.
    private var inFlight: [String: Int] = [:]
    private var flushTask: Task<Void, any Error>?
    private var loopTask: Task<Void, Never>?

    init(store: any HitStore, configuration: Configuration = Configuration(), logger: Logger = Logger(label: "hit-counter")) {
        precondition(configuration.maxPendingCodes > 0, "maxPendingCodes must be positive")
        self.store = store
        self.configuration = configuration
        self.logger = logger
    }

    // MARK: Recording

    /// Counts one hit for `code`. Never touches the database.
    func record(_ code: String) {
        pending[code, default: 0] += 1
        if pending.count >= configuration.maxPendingCodes, flushTask == nil {
            Task { await self.flushLoggingFailure() }
        }
    }

    /// Hits for `code` that the store doesn't know about yet (waiting or being written).
    /// Add this to the stored `hitCount` to get an exact number on a single server.
    func unflushedCount(for code: String) -> Int {
        pending[code, default: 0] + inFlight[code, default: 0]
    }

    // MARK: Flushing

    /// Writes all pending counts to the store. Waits for a flush already in progress first.
    /// On failure the counts are kept for the next attempt and the error is rethrown.
    func flush() async throws {
        // A running flush clears its own state before it completes, so this loop can't spin.
        while let running = flushTask {
            try await running.value
        }
        guard !pending.isEmpty else { return }

        let snapshot = pending
        pending = [:]
        inFlight = snapshot

        // Unstructured, so a cancelled caller doesn't abandon a write that is already under way.
        // It inherits this actor's isolation, so it only touches state between suspension points.
        let task = Task { () async throws -> Void in
            do {
                try await self.store.apply(snapshot)
                self.finishFlush()
            } catch {
                self.failFlush(restoring: snapshot)
                throw error
            }
        }
        flushTask = task
        try await task.value
    }

    private func finishFlush() {
        inFlight = [:]
        flushTask = nil
    }

    private func failFlush(restoring snapshot: [String: Int]) {
        for (code, count) in snapshot {
            pending[code, default: 0] += count
        }
        inFlight = [:]
        flushTask = nil
    }

    private func flushLoggingFailure() async {
        do {
            try await flush()
        } catch {
            logger.error("Hit count flush failed; will retry", metadata: ["error": "\(error)"])
        }
    }

    // MARK: Lifecycle

    /// Starts the periodic flush. Calling it twice has no effect.
    func start() {
        guard loopTask == nil else { return }
        let interval = configuration.flushInterval
        loopTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                await self.flushLoggingFailure()
            }
        }
    }

    /// Stops the periodic flush and writes whatever is still pending.
    func shutdown() async {
        let loop = loopTask
        loopTask = nil
        loop?.cancel()
        await loop?.value

        do {
            try await flush()
        } catch {
            let lost = pending.values.reduce(0, +)
            logger.error("Final hit count flush failed; counts lost",
                         metadata: ["error": "\(error)", "hits": "\(lost)"])
        }
    }
}

// MARK: - Application integration

/// Starts the periodic flush once the app has booted and flushes the remainder on shutdown.
struct HitCounterLifecycle: LifecycleHandler {
    let counter: HitCounter

    func didBootAsync(_ application: Application) async throws {
        await counter.start()
    }

    func shutdownAsync(_ application: Application) async {
        await counter.shutdown()
    }
}

private struct HitCounterKey: StorageKey {
    typealias Value = HitCounter
}

extension Application {
    var hitCounter: HitCounter {
        get {
            guard let counter = storage[HitCounterKey.self] else {
                fatalError("HitCounter not set; call configure(_:) first")
            }
            return counter
        }
        set { storage[HitCounterKey.self] = newValue }
    }
}
