import XCTest
@testable import ParcelKeeper

final class PickupTextParserTests: XCTestCase {
    private let parser = PickupTextParser()

    func testCainiaoHyphenLabelAndContentBracket() throws {
        let text = "您购买的宝贝已送达菜鸟驿站\n包裹待签收【取件码-3-4-1366】，手机号已加密，享号码保护服务，点击查看详情>>"
        let result = parser.parse(text)
        XCTAssertEqual(result.candidates.map(\.code), ["3-4-1366"])
        XCTAssertEqual(result.candidates.first?.location, "菜鸟驿站")
        XCTAssertNil(result.candidates.first?.source)
        XCTAssertFalse(result.isAmbiguous)
        for separator in ["-", "：", ":", "—", "－"] {
            XCTAssertEqual(parser.parse("【菜鸟】取件码\(separator)3-4-1366").candidates.first?.code, "3-4-1366")
        }
        XCTAssertTrue(parser.parse("订单号取件码-3-4-1366").candidates.isEmpty)
        XCTAssertTrue(parser.parse("https://example.test/取件码-3-4-1366").candidates.isEmpty)
    }

    func testFlattenedCainiaoNoticeDoesNotPolluteLocation() {
        let text = "您购买的宝贝已送达菜鸟驿站 包裹待签收【取件码-3-4-1366】，手机号已加密，享号码保护服务，点击查看详情>>"
        let result = parser.parse(text)
        XCTAssertEqual(result.candidates.map(\.code), ["3-4-1366"])
        XCTAssertEqual(result.candidates.first?.location, "菜鸟驿站")
        XCTAssertFalse(result.isAmbiguous)
    }

    func testExactRepeatedWholeNoticesAreOneButDifferentNoticesRemainAmbiguous() {
        let notice = "【菜鸟】取件码001，地点：东门。"
        for separator in ["\n", "\n\n", " "] {
            let result = parser.parse(notice + separator + notice)
            XCTAssertFalse(result.isAmbiguous, separator)
            XCTAssertEqual(result.candidates.count, 1)
            XCTAssertEqual(result.candidates.first?.location, "东门")
            XCTAssertEqual(result.candidates.first?.source, "菜鸟")
        }
        let multiline = "您购买的宝贝已送达菜鸟驿站\n包裹待签收【取件码-3-4-1366】，手机号已加密，享号码保护服务，点击查看详情>>"
        XCTAssertFalse(parser.parse(multiline + "\n" + multiline).isAmbiguous)
        for other in ["【菜鸟】取件码001，地点：西门。", "【菜鸟】取件码001，地点：东门。另一个订单"] {
            let result = parser.parse(notice + "\n" + other)
            XCTAssertTrue(result.isAmbiguous)
            XCTAssertNil(result.candidates.first?.location)
        }
        // Do not deduplicate a repeated line inside a different whole message.
        XCTAssertTrue(parser.parse("【甲】\n取件码001\n【乙】\n取件码001").isAmbiguous)
    }

    func testUnicodeHyphensAreNormalizedAcrossWholeTokens() {
        for separator in ["－", "﹣", "‐", "‑", "‒", "–", "—", "−"] {
            let code = "3\(separator)4\(separator)1366"
            let result = parser.parse("【菜鸟】取件码：\(code)")
            XCTAssertEqual(result.candidates.map(\.code), ["3-4-1366"], separator)
            XCTAssertFalse(result.isAmbiguous, separator)
            XCTAssertTrue(result.requiresConfirmation)
            XCTAssertTrue(parser.parse("订单号取件码\(code)").candidates.isEmpty, separator)
            XCTAssertTrue(parser.parse("https://example.test/取件码\(code)").candidates.isEmpty, separator)
        }
        XCTAssertEqual(parser.parse("取件码3－4-1366，00A—1#").candidates.map(\.code), ["3-4-1366", "00A-1#"])
    }

    func testOverlongTokensAreRejectedWithoutPrefixTruncation() {
        for code in [String(repeating: "1", count: 33), "3－4－" + String(repeating: "6", count: 33)] {
            XCTAssertTrue(parser.parse("取件码：\(code)").candidates.isEmpty, code)
            let list = parser.parse("取件码001、\(code)")
            XCTAssertEqual(list.candidates.map(\.code), ["001"], code)
            XCTAssertTrue(list.isAmbiguous, code)
        }
        let boundary = String(repeating: "0", count: 32)
        XCTAssertEqual(parser.parse("取件码\(boundary)").candidates.map(\.code), [boundary])
    }

    func testOverlongListItemsAreStructuralEvidenceNotValidCandidates() {
        let long = String(repeating: "A", count: 33)
        for separator in [",", "，", "、", "/", ";", "；"] {
            for text in ["取件码123\(separator)\(long)", "取件码\(long)\(separator)123", "取件码123，取件码\(long)"] {
                let result = parser.parse(text)
                XCTAssertTrue(result.isAmbiguous, text)
                XCTAssertEqual(result.candidates.map(\.code), ["123"], text)
            }
        }
        for suffix in ["https://example.test/ABC", "www.example.test/ABC", "456号楼", "A座"] {
            let result = parser.parse("取件码123，" + suffix)
            XCTAssertFalse(result.isAmbiguous, suffix)
            XCTAssertEqual(result.candidates.map(\.code), ["123"])
        }
    }

    func testLockerExample() throws {
        let result = parser.parse("【丰巢】凭取件码88772092至新港西路214号宿舍大院值班室旁丰巢柜取件。")
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(candidate.code, "88772092")
        XCTAssertEqual(candidate.location, "新港西路214号宿舍大院值班室旁丰巢柜")
        XCTAssertEqual(candidate.source, "丰巢")
        XCTAssertFalse(result.isAmbiguous)
        XCTAssertTrue(candidate.requiresConfirmation)
        XCTAssertTrue(result.requiresConfirmation)
    }

    func testFoodLeadingZerosAndSymbols() throws {
        let result = parser.parse("【示例餐厅】取餐码：00A-1#，地点：测试街一号店。")
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.code, "00A-1#")
        XCTAssertEqual(candidate.location, "测试街一号店")
        XCTAssertEqual(candidate.source, "示例餐厅")
    }

    func testNoLocationAndOtherLabel() throws {
        let result = parser.parse("取货码 00123")
        XCTAssertEqual(try XCTUnwrap(result.candidates.first).code, "00123")
        XCTAssertNil(result.candidates.first?.location)
        XCTAssertNil(result.candidates.first?.source)
    }

    func testIdentifiersAndURLsAreNotCodes() {
        let text = "网址 https://example.test/取件码123456 电话 13800138000 运单号 123456789012 订单号 ABC123"
        XCTAssertTrue(parser.parse(text).candidates.isEmpty)
        XCTAssertTrue(parser.parse("取件码：13800138000").candidates.isEmpty)
        for text in ["订单号取件码123456", "运单号：取件码123456", "手机号取货码123456", "电话取餐码123456"] {
            XCTAssertTrue(parser.parse(text).candidates.isEmpty, text)
        }
    }

    func testMultipleCodesAreAmbiguousWithoutInventingAssociations() {
        let result = parser.parse("取件码 001，取件码 A-2。地点：测试街一号。")
        XCTAssertEqual(result.candidates.map(\.code), ["001", "A-2"])
        XCTAssertTrue(result.isAmbiguous)
        XCTAssertTrue(result.candidates.allSatisfy { $0.location == nil && $0.requiresConfirmation })
    }

    func testMultipleLocationsAreAmbiguous() {
        let result = parser.parse("取件码 123，地址：测试街一号；地点：测试街二号。")
        XCTAssertTrue(result.isAmbiguous)
        XCTAssertNil(result.candidates.first?.location)
    }

    func testMultipleSourcesNeverGuessAssociations() {
        let result = parser.parse("【丰巢】取件码 001，地点：测试街一号。\n【示例餐厅】取餐码 A-2，地点：测试街二号。")
        XCTAssertEqual(result.candidates.map(\.code), ["001", "A-2"])
        XCTAssertTrue(result.isAmbiguous)
        XCTAssertTrue(result.candidates.allSatisfy { $0.source == nil && $0.location == nil })
    }

    func testRepeatedCodeAcrossSourcesIsAmbiguous() {
        let result = parser.parse("【甲】取件码 001，地点：测试街一号。\n【乙】取件码 001，地点：测试街二号。")
        XCTAssertEqual(result.candidates.map(\.code), ["001"])
        XCTAssertTrue(result.isAmbiguous)
        XCTAssertNil(result.candidates.first?.source)
        XCTAssertNil(result.candidates.first?.location)
    }

    func testSingleCodeWithMultipleSourcesDoesNotGuess() {
        let result = parser.parse("【甲】普通通知。\n【乙】取件码 001，地点：测试街一号。")
        XCTAssertTrue(result.isAmbiguous)
        XCTAssertNil(result.candidates.first?.source)
        XCTAssertNil(result.candidates.first?.location)
    }

    func testNoResultAndRepeatedCode() {
        XCTAssertTrue(parser.parse("普通通知，无取件信息。").candidates.isEmpty)
        let repeated = parser.parse("取件码 001，取件码 001。")
        XCTAssertEqual(repeated.candidates.count, 1)
        XCTAssertTrue(repeated.isAmbiguous)
        XCTAssertNil(repeated.candidates.first?.source)
        XCTAssertNil(repeated.candidates.first?.location)
    }
    func testPickupLabelAndCodeLists() {
        for label in ["提货码", "取件码", "取货码", "取餐码"] {
            let result = parser.parse("\(label)123、456，789")
            XCTAssertEqual(result.candidates.map(\.code), ["123", "456", "789"], label)
            XCTAssertTrue(result.isAmbiguous, label)
            XCTAssertTrue(result.candidates.allSatisfy { $0.location == nil })
        }
    }

    func testListDoesNotTreatAddressAsCode() {
        for suffix in ["地址：456号", "456号楼", "A座"] {
            let result = parser.parse("提货码123，\(suffix)")
            XCTAssertEqual(result.candidates.map(\.code), ["123"], suffix)
            XCTAssertFalse(result.isAmbiguous, suffix)
        }
    }

    func testRepeatedListCodeIsAmbiguous() {
        let result = parser.parse("提货码123、123")
        XCTAssertEqual(result.candidates.map(\.code), ["123"])
        XCTAssertTrue(result.isAmbiguous)
    }

    func testSharedFieldProtectionVariantsAndIndependentCodes() {
        let fields = ["订单", "訂單", "运单", "運單", "物流单", "物流單", "快递单", "快遞單", "手机", "手機", "电话", "電話", "单", "單"]
        for field in fields {
            for suffix in ["号", "號", "号码", "號碼", "编号", "編號"] {
                let prefix = field + suffix
                XCTAssertTrue(parser.parse("😀 \(prefix)：取件码1234").candidates.isEmpty, prefix)
                XCTAssertEqual(parser.parse("\(prefix)：987654，取件码1234").candidates.map(\.code), ["1234"], prefix)
            }
        }
        for text in ["HTTPS://example.test/取件码1234", "www.example.test/取件码1234", "订单号码：取件码为1234", "取件码13800138000"] {
            XCTAssertTrue(parser.parse(text).candidates.isEmpty, text)
        }
        for label in ["取件码", "取货码", "取餐码", "提货码"] {
            for code in ["001", "12345678", "00A-1#", String(repeating: "0", count: 32)] {
                XCTAssertEqual(parser.parse("\(label)：\(code)").candidates.map(\.code), [code])
            }
        }
    }

    func testUnsupportedTokensAreNotTruncatedAndTerminatorsRemainValid() {
        for code in ["ABC.123", "ABC/123", "ABC@123", "ABC=123"] {
            XCTAssertTrue(parser.parse("取件码" + code).candidates.isEmpty, code)
        }
        for code in ["00A-1#", "ABC_123", "ABC+123", "ABC*123"] {
            XCTAssertEqual(parser.parse("取件码" + code + ".").candidates.map(\.code), [code])
        }
    }

    func testPickupLabelInProtectedIdentifier() {
        XCTAssertTrue(parser.parse("订单号提货码123456").candidates.isEmpty)
    }

}
