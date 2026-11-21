//
//  CounterService.swift
//  URLShortener
//

import Vapor
import Fluent
import SQLKit

/// Hands out strictly increasing, never-repeated counter values.
///
/// Actor isolation is the lock: only one request at a time can take a value.
/// To avoid a DB write per request, values are reserved from the database in blocks;
/// the persisted high-water mark guarantees uniqueness across restarts
/// (unused values in a block are skipped after a restart, leaving harmless gaps).
///
/// Single-process only: the in-memory block assumes this process is the only consumer.
actor CounterService {
    static let counterName = "short_code"
    /// The counter starts at 0; codes are this many Base62 characters, zero-padded.
    static let startValue = 0
    static let codeLength = 7   // 62^7 ≈ 3.5 trillion codes
    private let blockSize: Int

    private var next = 0
    private var limit = 0   // exclusive upper bound of the in-memory block

    init(blockSize: Int = 1000) {
        self.blockSize = blockSize
    }

    /// The single refill in flight, if any. Concurrent callers wait on it instead of starting their own.
    private var refill: Task<Void, any Error>?

    func nextValue(on db: any Database) async throws -> Int {
        while next >= limit {
            if let inFlight = refill {
                // Someone is already refilling: wait for it, then re-check the block.
                try await inFlight.value
                continue
            }
            let size = blockSize
            // Task inherits actor isolation, so installing the block below is race-free.
            let task = Task {
                defer { self.refill = nil }
                let start = try await Self.reserveBlock(size: size, on: db)
                self.next = start
                self.limit = start + size
            }
            refill = task
            try await task.value
        }
        defer { next += 1 }
        return next
    }

    /// Atomically reserves `size` values and returns the start of the block.
    ///
    /// A single `UPDATE ... RETURNING` takes the row lock, increments, and reads in one step, so
    /// concurrent reservations (from any task or process) are serialized by Postgres and can
    /// never receive overlapping blocks. A separate read-then-write would allow lost updates.
    private static func reserveBlock(size: Int, on db: any Database) async throws -> Int {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Counter requires a SQL database")
        }
        let row = try await sql.raw("""
            UPDATE \(ident: CounterRecord.schema)
            SET "value" = "value" + \(literal: size)
            WHERE "name" = \(bind: counterName)
            RETURNING "value" - \(literal: size) AS "start"
            """).first()
        guard let row else {
            throw Abort(.internalServerError, reason: "Counter row '\(counterName)' is missing")
        }
        return try row.decode(column: "start", as: Int.self)
    }
}

private struct CounterServiceKey: StorageKey {
    typealias Value = CounterService
}

extension Application {
    var counterService: CounterService {
        if let existing = storage[CounterServiceKey.self] { return existing }
        let service = CounterService()
        storage[CounterServiceKey.self] = service
        return service
    }
}
