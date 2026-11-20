//
//  AddURLRecord.swift
//  URLShortener
//
//  Created by Rajasekar on 20/11/26.
//


import Fluent
import Vapor

struct AddURLRecord: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("url_records")
            .field("id", .int64, .identifier(auto: true))
            .field("shortCode", .string, .required)
            .field("longURL", .string, .required)
            .field("hitCount", .int, .required)
            .field("createdAt", .datetime)
            .unique(on: "shortCode")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("url_records").delete()
    }
}
