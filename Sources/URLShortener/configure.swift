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
    // Create the database on first start; migrations below only create tables inside it.
    await DatabaseBootstrap.ensureDatabaseExists(url: config.databaseURL, logger: app.logger)
    app.databases.use(try .postgres(url: config.databaseURL), as: .psql)

    // ── Redirect cache (in-process LRU; swap for a shared cache when running several instances) ──
    app.redirectCache = RedirectCache(configuration: .init(
        maxEntries: config.cacheMaxEntries,
        ttl: config.cacheTTL,
        negativeTTL: config.negativeCacheTTL
    ))

    // ── Hit counting: in-memory counts flushed to Postgres in batches ──
    // Registered after the database so shutdown flushes the counts before the database closes.
    let hitCounter = HitCounter(
        store: PostgresHitStore(database: app.db),
        configuration: .init(flushInterval: config.hitFlushInterval, maxPendingCodes: config.hitMaxPendingCodes),
        logger: app.logger
    )
    app.hitCounter = hitCounter
    app.lifecycle.use(HitCounterLifecycle(counter: hitCounter))

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
