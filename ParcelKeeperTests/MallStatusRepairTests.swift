import XCTest
@testable import ParcelKeeper

final class MallStatusRepairTests: XCTestCase {
    func testConditionalScopeAndStationSigningDoNotCompleteParcel() {
        for text in ["如果方便，完成取件后请评价", "预计明日，收件人已签收", "未实际签收", "包裹已签收至菜鸟驿站，等待取件", "驿站已签收，请凭码取件", "快递员已取件"] {
            XCTAssertNotEqual(MallDeliveryState.resolve(latest: text), .delivered, text)
        }
        XCTAssertEqual(MallDeliveryState.resolve(latest: "快件已送达菜鸟驿站，待您领取"), .readyForPickup)
        XCTAssertEqual(MallDeliveryState.resolve(latest: "收件人已签收，感谢使用"), .delivered)
    }
    func testCompletionVersusStationStorageAndNegation() {
        for text in ["快件已按约定投递，取件人凭取件码完成取件", "收件人凭取件码完成取件", "本人凭取件码完成取件", "您的快件已妥投，已在代收点取出", "包裹已签收", "收件人已取件"] {
            XCTAssertEqual(MallDeliveryState.resolve(latest: text), .delivered, text)
        }
        for text in ["快件送达丰巢暂存，请及时取件", "包裹已放入快递柜，等待取件", "快件已送达代收点，请凭码取件"] {
            XCTAssertEqual(MallDeliveryState.resolve(latest: text), .readyForPickup, text)
        }
        for text in ["预计明天派送，未签收", "尚未完成取件", "未妥投", "如已签收请忽略", "签收后请评价", "如果已取件请忽略"] {
            XCTAssertNil(MallDeliveryState.resolve(latest: text), text)
        }
        for text in ["请凭取件码完成取件", "请尽快完成取件", "请收件人凭取件码完成取件", "取件人需凭取件码完成取件", "取件人凭取件码完成取件后请评价", "如果方便，取件人凭取件码完成取件", "取件人尚未凭取件码完成取件"] {
            XCTAssertNotEqual(MallDeliveryState.resolve(latest: text), .delivered, text)
        }
        XCTAssertEqual(MallDeliveryState.resolve(latest: "快递员正在派送"), .outForDelivery)
        XCTAssertEqual(MallDeliveryState.resolve(latest: "快件已到达转运中心"), .inTransit)
        XCTAssertEqual(MallDeliveryState.resolve(latest: "正在派送，尚未签收"), .outForDelivery)
    }
    func testPDDShortCodeThreeRemainsVisibleWithoutRawBody() {
        let error = MallDirectError(reason: .unsupported, stage: "pdd-list", http: 200, bytes: 15, code: "3")
        XCTAssertTrue(error.localizedDescription.contains("代码=3"))
        XCTAssertFalse(error.localizedDescription.contains("前台重试"))
        XCTAssertFalse(MallDirectError(reason: .unsupported, stage: "pdd-list", code: "secret-cookie").localizedDescription.contains("secret-cookie"))
    }
}
