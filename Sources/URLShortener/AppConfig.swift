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

    static func load() -> AppConfig {
        let port = Environment.get("PORT").flatMap(Int.init) ?? 8080
        let baseURL = Environment.get("BASE_URL") ?? "http://localhost:\(port)"
        return AppConfig(
            // Default: local Postgres as the current OS user (the Homebrew default role), no password.
            databaseURL: Environment.get("DATABASE_URL")
                ?? "postgres://\(NSUserName())@localhost:5432/urlshortener",
            port: port,
            baseURL: baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
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
