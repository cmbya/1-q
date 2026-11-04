import XCTest
@testable import ParcelKeeper

final class MallPresentationTests: XCTestCase {
    func testMallNamesDoNotChangeCarrierOrActualSource() {
        for (raw, title) in [("jd", "京东"), ("pdd", "拼多多")] {
            var shipment = Shipment(trackingNumber: "SF123456789", carrierName: "顺丰速运", carrierCode: "sf")
            shipment.originPlatform = raw
            shipment.logisticsSource = "uapi"
            XCTAssertEqual(ShipmentRefreshPresentation.origin(shipment), title)
            XCTAssertEqual(ShipmentRefreshPresentation.source(shipment), "UAPI")
            XCTAssertEqual(shipment.carrierName, "顺丰速运")
            shipment.logisticsSource = raw
            XCTAssertEqual(ShipmentRefreshPresentation.source(shipment), title)
            XCTAssertTrue(ShipmentRefreshPresentation.details(shipment).contains("来源：" + title))
        }
    }

    func testMissingActualSourceDoesNotPretendImportWasSuccessfulRefresh() {
        var shipment = Shipment(trackingNumber: "JD123456789", carrierName: "京东物流", carrierCode: "jd")
        shipment.originPlatform = "jd"
        XCTAssertEqual(ShipmentRefreshPresentation.source(shipment), "未关联")
        XCTAssertTrue(ShipmentRefreshPresentation.details(shipment).contains("暂无物流轨迹"))
    }

    func testImportAndRefreshCountsAreReportedSeparately() {
        let report = MallImportSummary(added: 2, bound: 1, importFailed: 1, refreshed: 1, refreshFailed: 1, skipped: 1, previewApplied: 2, noTrace: 3)
        XCTAssertEqual(report.message, "导入：新增2票，已有记录补关联1票，失败1票。\n物流：保存本次预览2票，平台刷新1票，失败1票，无有效轨迹3票，保留／未请求1票。未调用UAPI或Tmini。")
    }

    func testSavedShortcutDefaultAndChannelsRemainUnchanged() {
        XCTAssertEqual((nil as QueryChannelChoice?).resolvedMode, .automatic)
        XCTAssertEqual(QueryChannelChoice.platformOnly.mode, .platformOnly)
        XCTAssertEqual(QueryChannelChoice.uapi.mode, .uapi)
    }
}
