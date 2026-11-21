import Foundation
import Testing
import Vapor
import Fluent
import VaporTesting
@testable import URLShortener

/// Integration tests run against a real Postgres database (default: `urlshortener_test`).
/// Create it once with `createdb urlshortener_test`, or point `TEST_DATABASE_URL` elsewhere.
/// The schema is reverted and re-migrated before every test and reverted again afterwards (pass or
/// fail), so the database is left empty when the run finishes. Never point this at a dev database.
private func withTestApp(_ body: (Application) async throws -> Void) async throws {
    let url = Environment.get("TEST_DATABASE_URL")
        ?? "postgres://\(NSUserName())@localhost:5432/urlshortener_test"
    setenv("DATABASE_URL", url, 1)

    let app = try await Application.make(.testing)
    do {
        try await configure(app)
        try await app.autoRevert()   // clear anything left by an earlier or aborted run
        try await app.autoMigrate()
        try await body(app)
    } catch {
        try? await app.autoRevert()
        try? await app.asyncShutdown()
        throw error
    }
    try await app.autoRevert()       // drop test data and tables
    try await app.asyncShutdown()
}

private func shorten(_ app: Application, _ url: String) async throws -> (status: HTTPStatus, code: String?) {
    var status: HTTPStatus = .internalServerError
    var code: String?
    try await app.testing().test(.POST, "api/shorten", beforeRequest: { req in
        try req.content.encode(["url": url])
    }, afterResponse: { res async throws in
        status = res.status
        code = try? res.content.decode(URLController.ShortenResponse.self).shortCode
    })
    return (status, code)
}

/// All integration tests share one database, so they must run one at a time (nested suites inherit this).
@Suite("Integration", .serialized)
enum Integration {}

extension Integration {
    @Suite("Counter")
    struct CounterServiceTests {
        @Test("Concurrent callers on one service never get the same value")
        func uniqueWithinProcess() async throws {
            try await withTestApp { app in
                let service = CounterService(blockSize: 10)   // small blocks → many refills
                let values = try await withThrowingTaskGroup(of: Int.self) { group in
                    for _ in 0..<500 { group.addTask { try await service.nextValue(on: app.db) } }
                    return try await group.reduce(into: [Int]()) { $0.append($1) }
                }
                #expect(values.count == 500)
                #expect(Set(values).count == 500)
            }
        }

        @Test("Separate services (simulating separate processes) never overlap")
        func uniqueAcrossServices() async throws {
            try await withTestApp { app in
                let a = CounterService(blockSize: 10)
                let b = CounterService(blockSize: 10)
                let values = try await withThrowingTaskGroup(of: Int.self) { group in
                    for i in 0..<1000 {
                        let service = i.isMultiple(of: 2) ? a : b
                        group.addTask { try await service.nextValue(on: app.db) }
                    }
                    return try await group.reduce(into: [Int]()) { $0.append($1) }
                }
                #expect(values.count == 1000)
                #expect(Set(values).count == 1000)
            }
        }

        @Test("Counter starts at 0")
        func startsAtZero() async throws {
            try await withTestApp { app in
                let service = CounterService()
                let value1 = try await service.nextValue(on: app.db)
                #expect(value1 == 0)
                let value2 = try await service.nextValue(on: app.db)
                #expect(value2 == 1)
            }
        }
    }

    @Suite("POST /api/shorten")
    struct ShortenEndpointTests {
        @Test("First code is 7 characters and zero-padded")
        func firstCode() async throws {
            try await withTestApp { app in
                let result = try await shorten(app, "https://example.com")
                #expect(result.status == .ok)
                #expect(result.code == "0000000")
            }
        }

        @Test("Same URL (including equivalent forms) returns the same code")
        func idempotent() async throws {
            try await withTestApp { app in
                let a = try await shorten(app, "https://example.com")
                let b = try await shorten(app, "https://EXAMPLE.com/")
                let c = try await shorten(app, "https://example.com:443/#frag")
                #expect(a.code != nil)
                #expect(a.code == b.code)
                #expect(a.code == c.code)
                let value3 = try await URLRecord.query(on: app.db).count()
                #expect(value3 == 1)
            }
        }

        @Test("Invalid URLs are rejected with 400")
        func invalid() async throws {
            try await withTestApp { app in
                let value4 = try await shorten(app, "ftp://example.com").status
                #expect(value4 == .badRequest)
                let value5 = try await shorten(app, "not a url").status
                #expect(value5 == .badRequest)
            }
        }

        @Test("Concurrent creates of distinct URLs all succeed with distinct codes")
        func concurrentDistinct() async throws {
            try await withTestApp { app in
                let results = try await withThrowingTaskGroup(of: (HTTPStatus, String?).self) { group in
                    for i in 0..<200 {
                        group.addTask { try await shorten(app, "https://load.test/\(i)") }
                    }
                    return try await group.reduce(into: [(HTTPStatus, String?)]()) { $0.append($1) }
                }
                #expect(results.allSatisfy { $0.0 == .ok })
                #expect(Set(results.compactMap { $0.1 }).count == 200)
                let value6 = try await URLRecord.query(on: app.db).count()
                #expect(value6 == 200)
            }
        }

        @Test("Concurrent creates of the same URL all return one code")
        func concurrentSame() async throws {
            try await withTestApp { app in
                let results = try await withThrowingTaskGroup(of: (HTTPStatus, String?).self) { group in
                    for _ in 0..<100 {
                        group.addTask { try await shorten(app, "https://same.test/") }
                    }
                    return try await group.reduce(into: [(HTTPStatus, String?)]()) { $0.append($1) }
                }
                #expect(results.allSatisfy { $0.0 == .ok })
                #expect(Set(results.compactMap { $0.1 }).count == 1)
                let value7 = try await URLRecord.query(on: app.db).count()
                #expect(value7 == 1)
            }
        }
    }
}
