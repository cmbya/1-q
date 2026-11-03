import XCTest
@testable import ParcelKeeper

final class JDCookieLoginTests: XCTestCase {
    func testPCThorWithoutPinIsAcceptedButMobileOnlyImportIsNot() throws {
        let cookies = try MallCookieImport.parse("thor=SYNTHETIC=tail; pin=fixture%40user;", platform: .jd)
        XCTAssertEqual(cookies.first?.value, "SYNTHETIC=tail")
        XCTAssertTrue(cookies.allSatisfy { $0.domain == ".jd.com" && $0.secure && $0.path == "/" })
        XCTAssertTrue(MallSession.hasJDPCSession(cookies))
        XCTAssertTrue(MallSession.hasLoginCredentials(cookies, platform: .jd))
        XCTAssertNoThrow(try MallCookieImport.parse("thor=SYNTHETIC", platform: .jd))
        for text in ["pt_key=fixture; pt_pin=fixture", "thor=", "Cookie: thor=fixture", "thor=a;thor=b", "thor=a\r\nX-Evil:b", "thor=a;broken", "PDDAccessToken=fixture;pdd_user_id=fixture"] {
            XCTAssertThrowsError(try MallCookieImport.parse(text, platform: .jd))
        }
    }
    func testPCPreflightRejectsForeignExpiredOrPathLimitedThor() {
        let invalid: [(String, String, Date?)] = [(".yangkeduo.com", "/", nil), (".jd.com", "/other", nil), (".jd.com", "/", .distantPast)]
        for (domain, path, expires) in invalid {
            let cookie = TaobaoTrialCookie(name: "thor", value: "SYNTHETIC", domain: domain, path: path, secure: true, expires: expires)
            XCTAssertFalse(MallSession.hasJDPCSession([cookie]))
        }
    }
}
