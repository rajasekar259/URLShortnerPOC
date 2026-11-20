//
//  URLRecord.swift
//  URLShortener
//
//  Created by Rajasekar on 20/11/26.
//


import Fluent
import Vapor

// A Fluent "Model" ≈ a Core Data entity, but it maps to a SQL table.
final class URLRecord: Model, Content, @unchecked Sendable {
    static let schema = "url_records"

    // ── Primary key (auto-increment) ──
    @ID(custom: .id)
    var id: Int?

    // ── Short code: 6-char alphanumeric, unique ──
    @Field(key: "shortCode")
    var shortCode: String

    // ── The long URL we're storing ──
    @Field(key: "longURL")
    var longURL: String

    // ── Timestamp ──
    @Timestamp(key: "createdAt", on: .create)
    var createdAt: Date?

    // ── Optional: track how many times it was hit ──
    @Field(key: "hitCount")
    var hitCount: Int

    init() {}

    init(id: Int? = nil,
         shortCode: String,
         longURL: String,
         hitCount: Int = 0) {
        self.id = id
        self.shortCode = shortCode
        self.longURL = longURL
        self.hitCount = hitCount
    }
}
