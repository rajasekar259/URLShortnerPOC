//
//  File.swift
//  URLShortener
//
//  Created by Rajasekar on 20/11/26.
//

import Vapor
import Fluent
import FluentPostgresDriver

func configure(_ app: Application) async throws {
    // ── Config (env vars with local defaults) ──
    let config = AppConfig.load()
    app.config = config
    app.http.server.configuration.port = config.port

    // ── Database ──
    app.databases.use(try .postgres(url: config.databaseURL), as: .psql)

    // ── Register migrations ──
    app.migrations.add(CreateURLRecord())
    app.migrations.add(CreateCounter())

    // ── Middleware (optional, add later) ──
    // app.middleware.use(FilesystemMiddleware(publicDirectory: app.directory.publicDirectory))
    // app.middleware.use(CORSMiddleware(config: .init(allowMethods: [.GET, .POST, .OPTIONS],
    //                                                  allowOrigins: .all,
    //                                                  allowHeaders: .default)))

    // ── Routes ──
    try routes(app)

    // ── Run pending migrations on launch ──
    try await app.autoMigrate()
    app.logger.info("Migrations applied; base URL \(config.baseURL)")
}
