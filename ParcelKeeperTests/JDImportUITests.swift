import XCTest
@testable import ParcelKeeper

final class JDImportUITests: XCTestCase {
    @MainActor
    func testJDImportUsesInAppReaderAndPDDKeepsDirectClient() {
        XCTAssertEqual(MallImportClient(platform: .jd, cookies: []).route, .jdInApp)
        XCTAssertEqual(MallImportClient(platform: .pdd, cookies: []).route, .pddDirect)
    }

    @MainActor
    func testConstructingReaderDoesNotVerifyOrReplaceStoredSession() throws {
        let keys = MemoryJDImportKeys()
        let session = MallSession(platform: .jd, keys: keys)
        let original = [TaobaoTrialCookie(name: "pt_key", value: "synthetic-key", domain: ".jd.com", path: "/", secure: true, expires: nil),
                        TaobaoTrialCookie(name: "pt_pin", value: "synthetic-pin", domain: ".jd.com", path: "/", secure: true, expires: nil)]
        try session.save(original)
        let saved = keys.value
        _ = MallImportClient(platform: .jd, cookies: [])
        XCTAssertEqual(keys.value, saved)
        XCTAssertEqual(keys.writes, 1)
    }
}

private final class MemoryJDImportKeys: AIKeyStore {
    var value: String?
    var writes = 0
    func read() throws -> String? { value }
    func save(_ value: String) throws { self.value = value; writes += 1 }
    func delete() throws { value = nil }
    func read(endpoint: String) throws -> String? { try read() }
    func save(_ key: String, endpoint: String) throws { try save(key) }
    func delete(endpoint: String) throws { try delete() }
}
