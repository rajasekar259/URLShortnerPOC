//
//  CreateURLRecord.swift
//  URLShortener
//

import Fluent
import SQLKit

struct CreateURLRecord: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(URLRecord.schema)
            .field("shortCode", .string, .identifier(auto: false))
            // SHA-256 of the normalized URL (32 raw bytes); unique → idempotent create
            .field("urlHash", .data, .required)
            .field("longURL", .string, .required)
            .field("hitCount", .int64, .required, .sql(.default(0)))
            .field("createdAt", .datetime, .required, .sql(.default(SQLFunction("now"))))
            .unique(on: "urlHash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(URLRecord.schema).delete()
    }
}
