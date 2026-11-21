import Foundation
import Testing
import Vapor
import Fluent
import VaporTesting
@testable import URLShortener

private enum TestSetupError: Error, CustomStringConvertible {
    case unsafeDatabase(String)

    var description: String {
        switch self {
        case .unsafeDatabase(let name):
            "Refusing to run integration tests against database '\(name)': its name must end in '_test'."
        }
    }
}

/// Integration tests run against a real Postgres database (default: `urlshortener_test`).
/// Create it once with `createdb urlshortener_test`, or point `TEST_DATABASE_URL` elsewhere.
/// The schema is reverted and re-migrated before every test and reverted again afterwards (pass or
/// fail), so the database is left empty when the run finishes. Never point this at a dev database.
private func withTestApp(_ body: (Application) async throws -> Void) async throws {
    let url = Environment.get("TEST_DATABASE_URL")
        ?? "postgres://\(NSUserName())@localhost:5432/urlshortener_test"
    // These tests drop every table when they finish, so refuse anything that isn't a `_test` database.
    let databaseName = URL(string: url)?.lastPathComponent ?? ""
    guard databaseName.hasSuffix("_test") else { throw TestSetupError.unsafeDatabase(databaseName) }
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
private struct Reply {
    var status: HTTPStatus
    var location: String?
    var body: ByteBuffer
}

private func send(_ app: Application, _ method: HTTPMethod, _ path: String) async throws -> Reply {
    var reply: Reply?
    try await app.testing().test(method, path, afterResponse: { res async throws in
        reply = Reply(status: res.status, location: res.headers.first(name: .location), body: res.body)
    })
    return try #require(reply)
}

private func lookup(_ app: Application, _ code: String) async throws -> (status: HTTPStatus, info: URLController.LookupResponse?) {
    var status: HTTPStatus = .internalServerError
    var info: URLController.LookupResponse?
    try await app.testing().test(.GET, "api/url/\(code)", afterResponse: { res async throws in
        status = res.status
        info = try? res.content.decode(URLController.LookupResponse.self)
    })
    return (status, info)
}

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

    @Suite("Other endpoints")
    struct OtherEndpointTests {
        @Test("GET /health returns ok")
        func health() async throws {
            try await withTestApp { app in
                let reply = try await send(app, .GET, "health")
                #expect(reply.status == .ok)
                #expect(String(buffer: reply.body) == "ok")
            }
        }

        @Test("GET /:code redirects to the normalized long URL")
        func redirects() async throws {
            try await withTestApp { app in
                let code = try #require(try await shorten(app, "https://EXAMPLE.com/Path?x=1").code)
                let reply = try await send(app, .GET, code)
                #expect(reply.status == .temporaryRedirect)
                #expect(reply.location == "https://example.com/Path?x=1")
            }
        }

        @Test("GET /:code for an unknown code returns 404")
        func redirectUnknown() async throws {
            try await withTestApp { app in
                let reply = try await send(app, .GET, "0000000")
                #expect(reply.status == .notFound)
                #expect(reply.location == nil)
            }
        }

        @Test("GET /api/url/:code returns metadata and counts redirects")
        func lookupMetadata() async throws {
            try await withTestApp { app in
                let code = try #require(try await shorten(app, "https://example.com").code)

                let before = try await lookup(app, code)
                #expect(before.status == .ok)
                #expect(before.info?.shortCode == code)
                #expect(before.info?.longURL == "https://example.com/")
                #expect(before.info?.hitCount == 0)

                _ = try await send(app, .GET, code)
                _ = try await send(app, .GET, code)

                let after = try await lookup(app, code)
                #expect(after.info?.hitCount == 2)
            }
        }

        @Test("GET /api/url/:code for an unknown code returns 404")
        func lookupUnknown() async throws {
            try await withTestApp { app in
                let hoisted1 = try await lookup(app, "0000000").status
                #expect(hoisted1 == .notFound)
            }
        }

        @Test("DELETE removes the link; lookup and redirect then return 404")
        func deleteRemoves() async throws {
            try await withTestApp { app in
                let code = try #require(try await shorten(app, "https://example.com").code)

                let deleted = try await send(app, .DELETE, "api/url/\(code)")
                #expect(deleted.status == .noContent)

                let hoisted2 = try await lookup(app, code).status

                #expect(hoisted2 == .notFound)
                let hoisted3 = try await send(app, .GET, code).status
                #expect(hoisted3 == .notFound)
                let hoisted4 = try await URLRecord.query(on: app.db).count()
                #expect(hoisted4 == 0)
            }
        }

        @Test("DELETE for an unknown code returns 404")
        func deleteUnknown() async throws {
            try await withTestApp { app in
                let hoisted5 = try await send(app, .DELETE, "api/url/0000000").status
                #expect(hoisted5 == .notFound)
            }
        }

        @Test("Re-creating a deleted URL issues a new code")
        func recreateAfterDelete() async throws {
            try await withTestApp { app in
                let first = try #require(try await shorten(app, "https://example.com").code)
                _ = try await send(app, .DELETE, "api/url/\(first)")
                let second = try #require(try await shorten(app, "https://example.com").code)
                #expect(second != first)
                let hoisted6 = try await send(app, .GET, second).status
                #expect(hoisted6 == .temporaryRedirect)
            }
        }
    }
}
