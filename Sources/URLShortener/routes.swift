//
//  routes.swift
//  URLShortener
//
//  Created by Rajasekar on 20/11/26.
//

import Vapor

func routes(_ app: Application) throws {
    // Health check — the "hello world" of any backend
    app.get("health") { req async throws -> String in
        return "ok"
    }

    // Wire up the controller
    let urlController = URLController()
    try app.register(collection: urlController)
}

