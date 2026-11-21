import Testing
@testable import URLShortener

@Suite("Base62")
struct Base62Tests {
    @Test("Fixed-width, zero-padded encoding", arguments: [
        (0, "0000000"),
        (1, "0000001"),
        (9, "0000009"),
        (10, "000000A"),
        (35, "000000Z"),
        (36, "000000a"),
        (61, "000000z"),
        (62, "0000010"),
        (3_844, "0000100"),
    ])
    func encodes(value: Int, expected: String) throws {
        #expect(try Base62.encode(value, width: 7) == expected)
    }

    @Test func maxValueFillsWidth() throws {
        let capacity = Base62.capacity(width: 7)
        #expect(capacity == 3_521_614_606_208)
        #expect(try Base62.encode(capacity - 1, width: 7) == "zzzzzzz")
    }

    @Test func overflowThrows() {
        #expect(throws: Base62.EncodingError.self) {
            try Base62.encode(Base62.capacity(width: 7), width: 7)
        }
    }

    @Test func alwaysFixedWidthAndUnique() throws {
        var seen = Set<String>()
        for value in 0..<20_000 {
            let code = try Base62.encode(value, width: 7)
            #expect(code.count == 7)
            #expect(seen.insert(code).inserted)
        }
    }
}

@Suite("URLNormalizer")
struct URLNormalizerTests {
    @Test("Equivalent URLs normalize identically", arguments: [
        "https://example.com",
        "https://EXAMPLE.com/",
        "  https://example.com/  ",
        "https://example.com:443/",
        "https://example.com/#section",
    ])
    func equivalent(raw: String) {
        #expect(URLNormalizer.normalize(raw) == "https://example.com/")
    }

    @Test("Query strings are preserved")
    func keepsQuery() {
        #expect(URLNormalizer.normalize("https://example.com/a?x=1") == "https://example.com/a?x=1")
    }

    @Test("Invalid URLs are rejected", arguments: [
        "", "ftp://example.com", "example.com", "https://user:pw@example.com", "https://",
    ])
    func rejects(raw: String) {
        #expect(URLNormalizer.normalize(raw) == nil)
    }

    @Test func hashIs32BytesAndStable() {
        let a = URLNormalizer.hash("https://example.com/")
        #expect(a.count == 32)
        #expect(a == URLNormalizer.hash("https://example.com/"))
        #expect(a != URLNormalizer.hash("https://example.org/"))
    }
}
