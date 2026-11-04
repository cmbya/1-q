import XCTest
@testable import ParcelKeeper

final class MallCookieImportTests: XCTestCase {
    func testCookieImportUsesPlatformDomainAndPreservesEquals() throws {
        let cookies = try MallCookieImport.parse("PDDAccessToken=fixture=tail; pdd_user_id=fixture-user;", platform: .pdd)
        XCTAssertEqual(cookies.first?.value, "fixture=tail")
        XCTAssertTrue(cookies.allSatisfy { $0.domain == ".yangkeduo.com" && $0.path == "/" && $0.secure })
        XCTAssertTrue(MallSession.hasLoginCredentials(cookies, platform: .pdd))
    }
    func testMalformedIncompleteAndInjectedCookiesAreRejected() {
        for text in ["", "analytics=a", "PDDAccessToken=a;PDDAccessToken=b;pdd_user_id=c", "PDDAccessToken=a\r\nHeader:x;pdd_user_id=c", "Cookie: PDDAccessToken=a;pdd_user_id=c", "PDDAccessToken=a;broken;pdd_user_id=c"] {
            XCTAssertThrowsError(try MallCookieImport.parse(text, platform: .pdd))
        }
        XCTAssertThrowsError(try MallCookieImport.parse("foreign_token=a;foreign_user=b", platform: .pdd))
        XCTAssertNoThrow(try MallCookieImport.parse("PDDAccessToken=fixture;pdd_user_id=123456", platform: .pdd))
    }
}

