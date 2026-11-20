//
//  File.swift
//  URLShortener
//
//  Created by Rajasekar on 20/11/26.
//

import Vapor
import Fluent
import FluentSQLiteDriver

// ── 1. Build the application ──
let app = try await Application.make(.detect())

do {
    // ── 2. Configure (DB, middleware, routes) ──
    try await configure(app)

    // ── 3. Start the HTTP server and never return ──
    //    This is the "run loop" equivalent of UIApplicationMain()
    try await app.execute()
} catch {
    try? await app.asyncShutdown()
    throw error
}
try await app.asyncShutdown()
