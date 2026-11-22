//
//  DatabaseBootstrap.swift
//  URLShortener
//

import Foundation
import Logging
import NIOCore
import PostgresKit
import PostgresNIO

/// Creates the target Postgres database on first start if it doesn't exist yet.
enum DatabaseBootstrap {
    /// Connects to the server's `postgres` maintenance database and runs `CREATE DATABASE` when the
    /// database named in `url` is missing. Does nothing if it already exists.
    ///
    /// Failures here are logged and swallowed: the real connection made afterwards reports the
    /// underlying problem (server down, bad credentials, no CREATEDB privilege) with a clearer error.
    static func ensureDatabaseExists(url: String, logger: Logger) async {
        do {
            let target = try SQLPostgresConfiguration(url: url).coreConfiguration
            guard let name = target.database, !name.isEmpty, name != maintenanceDatabase else { return }

            var admin = target
            admin.database = maintenanceDatabase
            let connection = try await PostgresConnection.connect(
                configuration: admin, id: 1, logger: logger
            )

            do {
                try await createIfMissing(name, using: connection, logger: logger)
            } catch {
                try? await connection.close()
                throw error
            }
            try await connection.close()
        } catch {
            logger.warning("Could not verify or create the database: \(error)")
        }
    }

    private static let maintenanceDatabase = "postgres"

    private static func createIfMissing(_ name: String, using connection: PostgresConnection, logger: Logger) async throws {
        let rows = try await connection.query(
            "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = \(name))", logger: logger
        )
        for try await exists in rows.decode(Bool.self) where exists { return }

        // Identifiers can't be bound as parameters, so quote it by hand.
        let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        do {
            try await connection.query(PostgresQuery(unsafeSQL: "CREATE DATABASE \(quoted)"), logger: logger)
            logger.info("Created database '\(name)'")
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "42P04" {
            // duplicate_database: another instance created it between our check and CREATE.
        }
    }
}
