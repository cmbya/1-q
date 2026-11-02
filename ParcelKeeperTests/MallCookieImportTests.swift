import XCTest
@testable import ParcelKeeper

final class MallCookieImportTests: XCTestCase {
    func testJDWebCredentialAlternativesRequireTicketAndIdentity() throws {
        for value in ["thor=fixture;pin=user", "pt_key=fixture;pin=user", "thor=fixture;pt_pin=user", "thor=fixture;_pst=user"] {
            XCTAssertNoThrow(try MallCookieImport.parse(value, platform: .jd))
        }
        for value in ["thor=fixture", "pin=user", "pt_key=;pt_pin=user", "thor=fixture;pin="] {
            XCTAssertThrowsError(try MallCookieImport.parse(value, platform: .jd))
        }
    }
    func testCookieImportUsesPlatformDomainAndPreservesEquals() throws {
        let cookies = try MallCookieImport.parse("pt_key=fixture=tail; pt_pin=fixture-user;", platform: .jd)
        XCTAssertEqual(cookies.first?.value, "fixture=tail")
        XCTAssertTrue(cookies.allSatisfy { $0.domain == ".jd.com" && $0.path == "/" && $0.secure })
        XCTAssertTrue(MallSession.hasLoginCredentials(cookies, platform: .jd))
    }
    func testMalformedIncompleteAndInjectedCookiesAreRejected() {
        for text in ["", "analytics=a", "pt_key=a;pt_key=b;pt_pin=c", "pt_key=a\r\nHeader:x;pt_pin=c", "Cookie: pt_key=a;pt_pin=c", "pt_key=a;broken;pt_pin=c"] {
            XCTAssertThrowsError(try MallCookieImport.parse(text, platform: .jd))
        }
        XCTAssertThrowsError(try MallCookieImport.parse("pt_key=a;pt_pin=b", platform: .pdd))
        XCTAssertNoThrow(try MallCookieImport.parse("PDDAccessToken=fixture;pdd_user_id=123456", platform: .pdd))
    }
}
