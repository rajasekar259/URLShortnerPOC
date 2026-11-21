//
//  PostgresHitStore.swift
//  URLShortener
//

import Vapor
import Fluent
import SQLKit

/// Persists hit counts with additive batched updates:
///
///     UPDATE url_records AS r SET "hitCount" = r."hitCount" + v.n
///     FROM (VALUES ($1::text, $2::bigint), ...) AS v(code, n)
///     WHERE r."shortCode" = v.code
///
/// The increment is relative, so it is atomic, safe under concurrency and safe across instances.
/// Codes that no longer exist (deleted links) simply match no row.
struct PostgresHitStore: HitStore {
    /// Rows per statement. Two bind parameters each, well under Postgres's 65,535 limit.
    static let batchSize = 1_000

    let database: any Database

    func apply(_ increments: [String: Int]) async throws {
        guard !increments.isEmpty else { return }
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Hit counts require a SQL database")
        }

        let entries = Array(increments)
        for start in stride(from: 0, to: entries.count, by: Self.batchSize) {
            let batch = entries[start ..< min(start + Self.batchSize, entries.count)]
            let rows: [SQLQueryString] = batch.map { code, count in
                "(\(bind: code)::text, \(bind: count)::bigint)"
            }
            try await sql.raw("""
                UPDATE \(ident: URLRecord.schema) AS r
                SET "hitCount" = r."hitCount" + v.n
                FROM (VALUES \(rows.joined(separator: ", "))) AS v(code, n)
                WHERE r."shortCode" = v.code
                """).run()
        }
    }
}
