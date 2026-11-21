//
//  CounterRecord.swift
//  URLShortener
//

import Fluent

/// Persisted high-water mark of the counter, so values are never reused after a restart.
final class CounterRecord: Model, @unchecked Sendable {
    static let schema = "counters"

    @ID(custom: "name", generatedBy: .user)
    var id: String?

    @Field(key: "value")
    var value: Int

    init() {}

    init(name: String, value: Int) {
        self.id = name
        self.value = value
    }
}
