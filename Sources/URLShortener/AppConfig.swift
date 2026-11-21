//
//  AppConfig.swift
//  URLShortener
//

import Foundation
import Vapor

/// Runtime settings, read from environment variables with local-development defaults.
struct AppConfig: Sendable {
    /// Postgres connection URL. Env: DATABASE_URL
    let databaseURL: String
    /// HTTP listen port. Env: PORT (the `--port` CLI flag still takes precedence)
    let port: Int
    /// Public origin used to build short URLs, without a trailing slash. Env: BASE_URL
    let baseURL: String
    /// Seconds between hit-count flushes to the database. Env: HIT_FLUSH_INTERVAL_SECONDS
    let hitFlushInterval: TimeInterval
    /// Flush early once this many distinct codes have unflushed hits. Env: HIT_MAX_PENDING_CODES
    let hitMaxPendingCodes: Int
    /// Redirect cache size, entry lifetime and not-found lifetime.
    /// Env: CACHE_MAX_ENTRIES, CACHE_TTL_SECONDS, NEGATIVE_CACHE_TTL_SECONDS
    let cacheMaxEntries: Int
    let cacheTTL: TimeInterval
    let negativeCacheTTL: TimeInterval

    static func load() -> AppConfig {
        let port = Environment.get("PORT").flatMap(Int.init) ?? 8080
        let baseURL = Environment.get("BASE_URL") ?? "http://localhost:\(port)"
        return AppConfig(
            // Default: local Postgres as the current OS user (the Homebrew default role), no password.
            databaseURL: Environment.get("DATABASE_URL")
                ?? "postgres://\(NSUserName())@localhost:5432/urlshortener",
            port: port,
            baseURL: baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL,
            hitFlushInterval: Environment.get("HIT_FLUSH_INTERVAL_SECONDS").flatMap(TimeInterval.init) ?? 5,
            hitMaxPendingCodes: Environment.get("HIT_MAX_PENDING_CODES").flatMap(Int.init) ?? 10_000,
            cacheMaxEntries: Environment.get("CACHE_MAX_ENTRIES").flatMap(Int.init) ?? 100_000,
            cacheTTL: Environment.get("CACHE_TTL_SECONDS").flatMap(TimeInterval.init) ?? 3_600,
            negativeCacheTTL: Environment.get("NEGATIVE_CACHE_TTL_SECONDS").flatMap(TimeInterval.init) ?? 30
        )
    }
}

private struct AppConfigKey: StorageKey {
    typealias Value = AppConfig
}

extension Application {
    var config: AppConfig {
        get {
            guard let config = storage[AppConfigKey.self] else {
                fatalError("AppConfig not set; call configure(_:) first")
            }
            return config
        }
        set { storage[AppConfigKey.self] = newValue }
    }
}
