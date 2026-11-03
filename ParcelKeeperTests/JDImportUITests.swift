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
    @MainActor
    func testCancellingPreparedSwitchDoesNotWriteOrClearExistingSession() throws {
        let keys = MemoryJDImportKeys()
        let session = MallSession(platform: .jd, keys: keys)
        let original = [TaobaoTrialCookie(name: "thor", value: "synthetic-pc", domain: ".jd.com", path: "/", secure: true, expires: nil)]
        try session.save(original)
        let saved = keys.value
        let generation = MallSession.generation(for: .jd)
        let prepared = JDLoginPolicy(mode: .switchAccount, cookies: try session.load())
        XCTAssertTrue(prepared.cookies.isEmpty)
        // Dismissing a candidate has no session write operation.
        XCTAssertEqual(keys.value, saved)
        XCTAssertEqual(keys.writes, 1)
        XCTAssertEqual(MallSession.generation(for: .jd), generation)
    }

    @MainActor
    func testNewCommitRejectsOldLoginAndItsContextCommitClosure() throws {
        let keys = MemoryJDImportKeys()
        let session = MallSession(platform: .jd, keys: keys)
        let original = [TaobaoTrialCookie(name: "thor", value: "synthetic-old", domain: ".jd.com", path: "/", secure: true, expires: nil)]
        let replacement = [TaobaoTrialCookie(name: "thor", value: "synthetic-new", domain: ".jd.com", path: "/", secure: true, expires: nil)]
        try session.save(original)
        let oldGeneration = MallSession.generation(for: .jd)
        try session.save(replacement, expectedGeneration: oldGeneration)
        var publishedOldContext = false
        XCTAssertThrowsError(try MallSession.withGeneration(platform: .jd, expected: oldGeneration) {
            try session.save(original, expectedGeneration: oldGeneration)
            publishedOldContext = true
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(publishedOldContext)
        XCTAssertEqual(try session.load().first?.value, "synthetic-new")
        XCTAssertEqual(keys.writes, 2)
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
