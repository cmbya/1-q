import XCTest
@testable import ParcelKeeper

final class ManualTaobaoReviewTests: XCTestCase {
    func testManualNumberPolicyRejectsIdentityChangingRepairs() throws {
        for raw in ["SF1234/567890", "SF1234-567890", "SF1234 567890", "单号SF1234567890", "13812345678", "ABCDEFGH", "1234567", String(repeating: "1", count: 29)] {
            XCTAssertThrowsError(try ShipmentShortcutParser.number(raw), raw)
        }
        XCTAssertEqual(try ShipmentShortcutParser.number("  sf1234567890\n"), "SF1234567890")
        XCTAssertEqual(try ShipmentShortcutParser.number("123456789012"), "123456789012")
    }

#if ENABLE_DIRECT_MALL_IMPORT
    func testUnknownUppercaseReturnCodesCannotLeakSecrets() {
        let secrets = ["ERROR_SECRET_COOKIE_ABCDEF", "FAIL_SECRET_TOKEN_ABCDEF", "FAIL_BIZ_ORDER_NOT_FOUND_SECRET"]
        for secret in secrets {
            let diagnostic = TaobaoTrialDiagnostic(stage: "物流详情", reason: .shape, status: 200,
                root: ["ret": [secret + "::private-response"]])
            XCTAssertEqual(diagnostic.codes, "未识别返回码")
            XCTAssertFalse(diagnostic.localizedDescription.contains(secret))
            XCTAssertFalse(diagnostic.localizedDescription.contains("private-response"))
        }
    }

    func testKnownDiagnosticCodesAndSchemaRemainUseful() {
        for code in ["SUCCESS", "FAIL_SYS_SESSION_EXPIRED", "FAIL_SYS_TOKEN_EXOIRED", "FAIL_SYS_USER_VALIDATE", "FAIL_SYS_ILLEGAL_ACCESS", "FAIL_BIZ_ORDER_NOT_FOUND"] {
            let diagnostic = TaobaoTrialDiagnostic(stage: "物流详情", reason: .shape, status: 200,
                root: ["ret": [code + "::private-response"], "data": ["mailNo": "private-waybill"]])
            XCTAssertEqual(diagnostic.codes, code)
            XCTAssertTrue(diagnostic.localizedDescription.contains("运单字段=是"))
            XCTAssertFalse(diagnostic.localizedDescription.contains("private-response"))
            XCTAssertFalse(diagnostic.localizedDescription.contains("private-waybill"))
        }
    }
#endif
}
