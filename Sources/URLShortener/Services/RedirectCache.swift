//
//  RedirectCache.swift
//  URLShortener
//

import Foundation
import Vapor

/// Resolves short codes to long URLs without hitting the database on every request.
///
/// Kept behind a protocol so a Redis-backed implementation can replace the in-process one
/// when the app runs on more than one instance.
protocol RedirectCaching: Sendable {
    /// Returns the cached long URL for `code`, calling `load` on a miss.
    /// `load` returns nil when the code does not exist; that result is cached briefly too.
    func resolve(_ code: String, load: @escaping @Sendable () async throws -> String?) async throws -> String?
    /// Write-through for a newly created link.
    func store(_ code: String, longURL: String) async
    /// Forget a code (call when a link is deleted).
    func invalidate(_ code: String) async
}

/// In-process LRU cache with a TTL, a short-lived negative cache and single-flight loading.
///
/// - Bounded: least-recently-used entries are evicted beyond `maxEntries`.
/// - Entries expire after `ttl` (a safety net; links never change after creation).
/// - Codes that do not exist are remembered for `negativeTTL` so bad requests don't reach the database.
/// - Concurrent misses for the same code share one `load` call.
actor RedirectCache: RedirectCaching {
    struct Configuration: Sendable {
        var maxEntries = 100_000
        var ttl: TimeInterval = 3_600
        var negativeTTL: TimeInterval = 30
    }

    struct Stats: Sendable, Equatable {
        var hits = 0
        var negativeHits = 0
        var misses = 0          // lookups that had to load (the loader is called once per miss)
        var coalesced = 0       // lookups that joined a load already in flight
        var evictions = 0
    }

    private enum Value {
        case url(String)
        case missing
    }

    private struct Entry {
        var value: Value
        var expiresAt: TimeInterval
    }

    private struct InFlight {
        let id: Int
        let task: Task<String?, any Error>
    }

    private let configuration: Configuration
    private let now: @Sendable () -> TimeInterval

    private var entries: LRUCache<String, Entry>
    private var inFlight: [String: InFlight] = [:]
    private var nextLoadID = 0

    private(set) var stats = Stats()

    /// `now` is a monotonic clock in seconds; tests inject their own.
    init(configuration: Configuration = Configuration(),
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        precondition(configuration.maxEntries > 0, "maxEntries must be positive")
        self.configuration = configuration
        self.entries = LRUCache(capacity: configuration.maxEntries)
        self.now = now
    }

    var count: Int { entries.count }

    // MARK: RedirectCaching

    func resolve(_ code: String, load: @escaping @Sendable () async throws -> String?) async throws -> String? {
        if let cached = lookup(code) {
            switch cached {
            case .url(let url):
                stats.hits += 1
                return url
            case .missing:
                stats.negativeHits += 1
                return nil
            }
        }

        if let existing = inFlight[code] {
            stats.coalesced += 1
            return try await existing.task.value
        }

        stats.misses += 1
        let id = nextLoadID
        nextLoadID += 1
        // An unstructured task, so one caller being cancelled doesn't cancel the load the others share.
        // It inherits this actor's isolation, so it only touches the cache between suspension points.
        let task = Task { () async throws -> String? in
            do {
                let url = try await load()
                self.finishLoad(code, id: id, url: url)
                return url
            } catch {
                self.abandonLoad(code, id: id)
                throw error
            }
        }
        inFlight[code] = InFlight(id: id, task: task)
        return try await task.value
    }

    func store(_ code: String, longURL: String) {
        inFlight[code] = nil   // a load that started earlier must not overwrite this
        insert(code, .url(longURL), ttl: configuration.ttl)
    }

    func invalidate(_ code: String) {
        inFlight[code] = nil   // a load that started earlier must not resurrect the entry
        entries.removeValue(for: code)
    }

    // MARK: Load bookkeeping

    private func finishLoad(_ code: String, id: Int, url: String?) {
        // Skip if the code was stored or invalidated while the load was running.
        guard inFlight[code]?.id == id else { return }
        inFlight[code] = nil
        if let url {
            insert(code, .url(url), ttl: configuration.ttl)
        } else {
            insert(code, .missing, ttl: configuration.negativeTTL)
        }
    }

    private func abandonLoad(_ code: String, id: Int) {
        if inFlight[code]?.id == id { inFlight[code] = nil }
    }

    // MARK: Storage (recency order is handled by LRUCache; expiry is policy and lives here)

    /// Returns the live value for `key` and marks it most recently used; expired entries are dropped.
    private func lookup(_ key: String) -> Value? {
        guard let entry = entries.value(for: key) else { return nil }
        if entry.expiresAt <= now() {
            entries.removeValue(for: key)
            return nil
        }
        return entry.value
    }

    private func insert(_ key: String, _ value: Value, ttl: TimeInterval) {
        let entry = Entry(value: value, expiresAt: now() + ttl)
        if entries.setValue(entry, for: key) != nil {
            stats.evictions += 1
        }
    }
}

// MARK: - Application integration

private struct RedirectCacheKey: StorageKey {
    typealias Value = RedirectCache
}

extension Application {
    var redirectCache: RedirectCache {
        get {
            guard let cache = storage[RedirectCacheKey.self] else {
                fatalError("RedirectCache not set; call configure(_:) first")
            }
            return cache
        }
        set { storage[RedirectCacheKey.self] = newValue }
    }
}
