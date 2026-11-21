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

    // ── Primary key: the Base62 short code itself ──
    @ID(custom: "shortCode", generatedBy: .user)
    var id: String?

    // ── SHA-256 of the normalized long URL, 32 raw bytes (unique → idempotent create) ──
    @Field(key: "urlHash")
    var urlHash: Data

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

    init(shortCode: String, urlHash: Data, longURL: String, hitCount: Int = 0) {
        self.id = shortCode
        self.urlHash = urlHash
        self.longURL = longURL
        self.hitCount = hitCount
    }
}
