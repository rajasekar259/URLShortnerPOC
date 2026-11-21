//
//  URLNormalizer.swift
//  URLShortener
//

import Foundation
import Crypto

/// Canonicalizes URLs so equivalent inputs produce the same hash.
enum URLNormalizer {
    static let maxLength = 2048

    /// Returns the canonical form of `raw`, or nil if it isn't an acceptable http(s) URL.
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }

        components.scheme = scheme
        components.host = host
        components.fragment = nil

        // Drop default ports
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        // "https://example.com" and "https://example.com/" are the same resource
        if components.path.isEmpty {
            components.path = "/"
        }
        return components.string
    }

    /// SHA-256 of the (already normalized) URL, as 32 raw bytes.
    static func hash(_ normalizedURL: String) -> Data {
        Data(SHA256.hash(data: Data(normalizedURL.utf8)))
    }
}
