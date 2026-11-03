import XCTest
@testable import ParcelKeeper

final class PlatformCookieAttributeTests: XCTestCase {
    func testOldSessionWithoutHTTPOnlyStillDecodes() throws {
        let json = Data(#"{"name":"pt_key","value":"synthetic","domain":".jd.com","path":"/","secure":true}"#.utf8)
        let stored = try JSONDecoder().decode(TaobaoTrialCookie.self, from: json)
        XCTAssertNil(stored.httpOnly)
        let cookie = try XCTUnwrap(stored.webCookie())
        XCTAssertTrue(cookie.isSecure)
        XCTAssertEqual(cookie.path, "/")
    }
    func testNativeReinjectionPreservesHTTPOnlySecurePathAndExpiry() throws {
        // Foundation caps far-future Cookie expiries. Verify exact preservation
        // inside the system-supported window, without subsecond rounding noise.
        let expires = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 86_400)
        let stored = TaobaoTrialCookie(name: "pt_key", value: "synthetic", domain: ".jd.com", path: "/order", secure: true, expires: expires, httpOnly: true)
        let roundTrip = try JSONDecoder().decode(TaobaoTrialCookie.self, from: JSONEncoder().encode(stored))
        let cookie = try XCTUnwrap(roundTrip.webCookie())
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertTrue(cookie.isSecure)
        XCTAssertEqual(cookie.path, "/order")
        XCTAssertEqual(cookie.expiresDate, expires)
        XCTAssertEqual(cookie.value, "synthetic")
    }
}
