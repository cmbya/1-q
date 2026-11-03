import XCTest
@testable import ParcelKeeper

final class JDSessionResumeTests: XCTestCase {
    private func mobile(expires: Date? = nil) -> [TaobaoTrialCookie] {
        [TaobaoTrialCookie(name: "pt_key", value: "synthetic-key", domain: ".jd.com", path: "/", secure: true, expires: expires, httpOnly: true),
         TaobaoTrialCookie(name: "pt_pin", value: "synthetic-pin", domain: ".jd.com", path: "/", secure: true, expires: expires)]
    }

    func testResumeStartsAtOrdersWithSavedMobileAttributes() {
        let saved = mobile(expires: Date().addingTimeInterval(3600))
        let policy = JDLoginPolicy(mode: .resume, cookies: saved)
        XCTAssertEqual(policy.initialURL, MallPlatform.jd.ordersURL)
        XCTAssertEqual(policy.cookies.map(\.name), ["pt_key", "pt_pin"])
        XCTAssertTrue(policy.cookies[0].secure)
        XCTAssertEqual(policy.cookies[0].httpOnly, true)
        XCTAssertEqual(policy.cookies[0].expires, saved[0].expires)
        XCTAssertFalse(policy.pcSessionSaved)
    }

    func testSwitchNeverSeedsPreviousAccountIncludingPC() {
        let policy = JDLoginPolicy(mode: .switchAccount, cookies: mobile() + [thor()])
        XCTAssertTrue(policy.cookies.isEmpty)
        XCTAssertEqual(policy.initialURL, MallPlatform.jd.loginURL)
        XCTAssertFalse(policy.pcSessionSaved)
    }

    func testPCSessionCannotBeConvertedEvenWithMobileCookiesPresent() {
        let policy = JDLoginPolicy(mode: .resume, cookies: [thor()] + mobile())
        XCTAssertTrue(policy.pcSessionSaved)
        XCTAssertTrue(policy.cookies.isEmpty)
        XCTAssertNil(policy.initialURL)
    }

    func testMissingOrExpiredMobileSessionStartsAtLogin() {
        for cookies in [[], mobile(expires: Date().addingTimeInterval(-60)), [mobile()[0]]] {
            let policy = JDLoginPolicy(mode: .resume, cookies: cookies)
            XCTAssertTrue(policy.cookies.isEmpty)
            XCTAssertEqual(policy.initialURL, MallPlatform.jd.loginURL)
        }
    }

    func testResumeDoesNotSeedExpiredOrForeignCookies() {
        let extra = [TaobaoTrialCookie(name: "old", value: "synthetic", domain: ".jd.com", path: "/", secure: true, expires: Date().addingTimeInterval(-60)),
                     TaobaoTrialCookie(name: "foreign", value: "synthetic", domain: ".example.com", path: "/", secure: true, expires: nil)]
        let policy = JDLoginPolicy(mode: .resume, cookies: mobile() + extra)
        XCTAssertEqual(policy.cookies.map(\.name), ["pt_key", "pt_pin"])
    }

    func testNavigationFailureHasFixedSafeReasonRatherThanUnknown() {
        let failures: [(Error, DiagnosticReason)] = [
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), .timeout),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), .network),
            (NSError(domain: "arbitrary-private-domain-with-session", code: 999999), .network)
        ]
        for (error, expected) in failures {
            let safe = JDLoginPolicy.navigationFailure(error) as? JDLoggedError
            XCTAssertEqual(safe?.reason, expected)
            XCTAssertEqual(safe?.stage, .jdLogin)
            XCTAssertFalse(safe?.localizedDescription.contains("arbitrary-private") ?? true)
        }
        XCTAssertTrue(JDLoginPolicy.navigationFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)) is CancellationError)
    }

    private func thor() -> TaobaoTrialCookie {
        TaobaoTrialCookie(name: "thor", value: "synthetic-pc", domain: ".jd.com", path: "/", secure: true, expires: nil)
    }
}
