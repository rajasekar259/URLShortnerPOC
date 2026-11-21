//
//  URLController.swift
//  URLShortener
//
//  Created by Rajasekar on 20/11/26.
//


import Vapor
import Fluent
import FluentPostgresDriver

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

        // Validate and canonicalize so equivalent URLs hash identically
        guard let normalized = URLNormalizer.normalize(body.url) else {
            throw Abort(.badRequest, reason: "Must be a valid http(s) URL")
        }
        let urlHash = URLNormalizer.hash(normalized)

        // Idempotent: the same URL always returns the same short code
        let record: URLRecord
        if let existing = try await URLRecord.query(on: req.db)
            .filter(\.$urlHash == urlHash).first() {
            record = existing
        } else {
            // Unique counter value → Base62 code (no collisions, no retry loop)
            let counter = try await req.application.counterService.nextValue(on: req.db)
            let code: String
            do {
                code = try Base62.encode(counter, width: CounterService.codeLength)
            } catch {
                req.logger.critical("Short code space exhausted at counter \(counter)")
                throw Abort(.serviceUnavailable, reason: "Short code space exhausted")
            }
            let created = URLRecord(shortCode: code,
                                    urlHash: urlHash,
                                    longURL: normalized)
            do {
                try await created.create(on: req.db)
                record = created
            } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
                // unique_violation: a concurrent request inserted the same URL first (unique urlHash).
                // Return its code. Any other database error is a real failure and propagates.
                guard let existing = try await URLRecord.query(on: req.db)
                    .filter(\.$urlHash == urlHash).first() else { throw error }
                record = existing
            }
        }

        let shortCode = try record.requireID()
        let shortURL = "\(req.application.config.baseURL)/\(shortCode)"
        return ShortenResponse(shortCode: shortCode, shortURL: shortURL, longURL: record.longURL)
    }

    // ──────────────────────────────────────────────
    // GET /{shortCode}  →  302 redirect
    // ──────────────────────────────────────────────
    func redirect(_ req: Request) async throws -> Response {
        let code = try req.parameters.require("shortCode")

        guard let record = try await URLRecord.find(code, on: req.db) else {
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
        guard let record = try await URLRecord.find(code, on: req.db) else {
            throw Abort(.notFound, reason: "Not found")
        }
        return LookupResponse(
            shortCode: code,
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
        guard let record = try await URLRecord.find(code, on: req.db) else {
            throw Abort(.notFound)
        }
        try await record.delete(on: req.db)
        return .noContent
    }
}
