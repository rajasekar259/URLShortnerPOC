//
//  CreateCounter.swift
//  URLShortener
//

import Fluent

struct CreateCounter: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(CounterRecord.schema)
            .field("name", .string, .identifier(auto: false))
            .field("value", .int64, .required)
            .create()

        // Seed the single row so the allocator only ever updates it.
        try await CounterRecord(name: CounterService.counterName, value: CounterService.startValue)
            .create(on: database)
    }

    func revert(on database: any Database) async throws {
        try await database.schema(CounterRecord.schema).delete()
    }
}
