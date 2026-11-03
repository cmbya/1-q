import XCTest
@testable import ParcelKeeper

final class KDYZMPairingTests: XCTestCase {
    private func json(version: String = "1", base: String = "https://Example.COM:443/", code: String = "0123456789ABCDEF") -> String {
        "{\"schemaVersion\":\(version),\"baseUrl\":\"\(base)\",\"code\":\"\(code)\"}"
    }
    func testOfficialJSONNormalizesOriginAndPreservesCode() throws {
        let payload = try KDYZMPairingPayload(raw: json())
        XCTAssertEqual(payload.origin, "https://example.com")
        XCTAssertEqual(payload.code, "0123456789ABCDEF")
        XCTAssertEqual(try KDYZMPairingPayload(raw: json(base: "https://example.com:8443")).origin, "https://example.com:8443")
    }
    func testSchemaDoesNotCoerceBooleanStringOrFraction() {
        for version in ["true", "false", "\"1\"", "null", "0", "2", "1.1", "{}", "[]"] {
            XCTAssertThrowsError(try KDYZMPairingPayload(raw: json(version: version)))
        }
    }
    func testRejectsUnsafeOrigins() {
        for base in ["http://example.com", "https://user:pass@example.com", "https://example.com/path", "https://example.com?x=1", "https://example.com#fragment", " https://example.com", "https://example.com:65536", "javascript:alert(1)", "parcelkeeper://pair"] {
            XCTAssertThrowsError(try KDYZMPairingPayload(raw: json(base: base)))
        }
    }
    func testOfficialCodeShapeIsExact() {
        for code in ["", "0123456789ABCDE", "0123456789ABCDEFG", "0123456789abcdef", "0123456789ABCDEG", " 0123456789ABCDEF", "0123456789ABCDEF "] {
            XCTAssertThrowsError(try KDYZMPairingPayload(raw: json(code: code)))
        }
    }
    func testMalformedWrongTypesMissingAndUnknownFields() {
        for raw in ["", "not JSON", "https://example.com", "[]", "null", "{}", "{\"schemaVersion\":1}", "{\"schemaVersion\":1,\"baseUrl\":7,\"code\":\"0123456789ABCDEF\"}", "{\"schemaVersion\":1,\"baseUrl\":\"https://example.com\",\"code\":12}", String(json().dropLast()) + ",\"token\":\"untrusted\"}", String(repeating: "a", count: 4097)] {
            XCTAssertThrowsError(try KDYZMPairingPayload(raw: raw))
        }
    }
    func testSingleShotInputRejectsMultipleEvenIdenticalCodes() throws {
        XCTAssertThrowsError(try KDYZMPairingPayload.single([]))
        XCTAssertThrowsError(try KDYZMPairingPayload.single([json(), json()])) { error in
            guard case KDYZMPairingScanError.multipleCodes = error else { return XCTFail("Expected ambiguity rejection") }
        }
        XCTAssertEqual(try KDYZMPairingPayload.single([json()]), try KDYZMPairingPayload(raw: json()))
    }
}
