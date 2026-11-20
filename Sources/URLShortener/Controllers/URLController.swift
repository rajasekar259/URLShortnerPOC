//
//  URLController.swift
//  URLShortener
//
//  Created by Rajasekar on 20/11/26.
//


import Vapor
import Fluent

// A "RouteCollection" is a group of endpoints, like a child router.
struct URLController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // ── Create a short URL ──
        routes.post("api", "shorten", use: create)

        // ── Redirect: /{shortCode} → 302 to long URL ──
        routes.get(":shortCode", use: redirect)

        // ── Look up metadata for a code ──
        routes.get("api", "url", ":shortCode", use: lookup)

        // ── Delete (with auth later) ──
        routes.delete("api", "url", ":shortCode", use: delete)
    }

    // ──────────────────────────────────────────────
    // POST /api/shorten   body: { "url": "https://..." }
    // ──────────────────────────────────────────────
    struct ShortenRequest: Content {
        var url: String
    }
    struct ShortenResponse: Content {
        var shortCode: String
        var shortURL: String
        var longURL: String
    }

    func create(_ req: Request) async throws -> ShortenResponse {
        let body = try req.content.decode(ShortenRequest.self)

        // Basic validation
        guard let _ = URL(string: body.url),
              let scheme = URL(string: body.url)?.scheme,
              ["http", "https"].contains(scheme) else {
            throw Abort(.badRequest, reason: "Must be a valid http(s) URL")
        }

        // Generate a 6-char code (you'll see collisions handled by retry)
        var shortCode = Self.generateCode()
        while try await URLRecord.query(on: req.db)
            .filter(\.$shortCode == shortCode)
            .first() != nil {
            shortCode = Self.generateCode()
        }

        let record = URLRecord(shortCode: shortCode, longURL: body.url)
        try await record.save(on: req.db)

        let shortURL = "http://localhost:8080/\(shortCode)"
        return ShortenResponse(shortCode: shortCode, shortURL: shortURL, longURL: body.url)
    }

    // ──────────────────────────────────────────────
    // GET /{shortCode}  →  302 redirect
    // ──────────────────────────────────────────────
    func redirect(_ req: Request) async throws -> Response {
        let code = try req.parameters.require("shortCode")

        guard let record = try await URLRecord
            .query(on: req.db)
            .filter(\.$shortCode == code)
            .first() else {
            throw Abort(.notFound, reason: "Short code '\(code)' not found")
        }

        // Bump hit counter
        record.hitCount += 1
        try await record.save(on: req.db)

        // 302 = "go look elsewhere". In a browser this is transparent.
        return req.redirect(to: record.longURL, redirectType: .temporary)
    }

    // ──────────────────────────────────────────────
    // GET /api/url/:shortCode  →  JSON metadata
    // ──────────────────────────────────────────────
    struct LookupResponse: Content {
        var shortCode: String
        var longURL: String
        var hitCount: Int
        var createdAt: Date
    }

    func lookup(_ req: Request) async throws -> LookupResponse {
        let code = try req.parameters.require("shortCode")
        guard let record = try await URLRecord
            .query(on: req.db)
            .filter(\.$shortCode == code)
            .first() else {
            throw Abort(.notFound, reason: "Not found")
        }
        return LookupResponse(
            shortCode: record.shortCode,
            longURL:   record.longURL,
            hitCount:  record.hitCount,
            createdAt: record.createdAt ?? Date()
        )
    }

    // ──────────────────────────────────────────────
    // DELETE /api/url/:shortCode
    // ──────────────────────────────────────────────
    func delete(_ req: Request) async throws -> HTTPStatus {
        let code = try req.parameters.require("shortCode")
        guard let record = try await URLRecord
            .query(on: req.db)
            .filter(\.$shortCode == code)
            .first() else {
            throw Abort(.notFound)
        }
        try await record.delete(on: req.db)
        return .noContent
    }

    // ──────────────────────────────────────────────
    // Helper: 6-char code from SecureRandom
    // ──────────────────────────────────────────────
    private static func generateCode() -> String {
        // In production use a Snowflake ID or Redis INCR for zero collisions.
        // For local dev, random + retry-on-collision is fine.
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        var rng = SystemRandomNumberGenerator()
        return String((0..<6).compactMap { _ in
            chars.randomElement(using: &rng)
        })
    }
}
