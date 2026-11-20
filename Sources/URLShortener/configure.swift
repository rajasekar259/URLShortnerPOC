//
//  File.swift
//  URLShortener
//
//  Created by Rajasekar on 20/11/26.
//

import Vapor
import Fluent
import FluentSQLiteDriver

func configure(_ app: Application) async throws {
    // ── Database ──
    // SQLite file lives in the project root. No server process, no port.
    app.databases.use(.sqlite(.file("url_shortener.db")), as: .sqlite)

    // ── Register migrations ──
    app.migrations.add(AddURLRecord())

    // ── Middleware (optional, add later) ──
    // app.middleware.use(FilesystemMiddleware(publicDirectory: app.directory.publicDirectory))
    // app.middleware.use(CORSMiddleware(config: .init(allowMethods: [.GET, .POST, .OPTIONS],
    //                                                  allowOrigins: .all,
    //                                                  allowHeaders: .default)))

    // ── Routes ──
    try routes(app)

    // ── Run pending migrations on launch ──
    try await app.autoMigrate()
    print("✅ Migrations applied. Listening on http://localhost:8080")
}
