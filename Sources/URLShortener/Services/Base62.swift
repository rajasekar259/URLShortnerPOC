//
//  Base62.swift
//  URLShortener
//

enum Base62 {
    enum EncodingError: Error {
        /// The value needs more digits than the requested fixed width.
        case overflow
    }

    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// Number of distinct values representable in `width` Base62 digits (62^width).
    static func capacity(width: Int) -> Int {
        (0..<width).reduce(1) { acc, _ in acc * 62 }
    }

    /// Encodes a non-negative integer as a Base62 string, left-padded with the zero digit ("0")
    /// to exactly `width` characters. Throws `.overflow` if the value doesn't fit.
    static func encode(_ value: Int, width: Int) throws -> String {
        precondition(value >= 0, "Base62 only encodes non-negative values")
        guard value < capacity(width: width) else { throw EncodingError.overflow }

        var digits = [Character](repeating: alphabet[0], count: width)
        var n = value
        var index = width - 1
        while n > 0 {
            digits[index] = alphabet[n % 62]
            n /= 62
            index -= 1
        }
        return String(digits)
    }
}
