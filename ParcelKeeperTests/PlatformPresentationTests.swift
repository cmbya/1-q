import XCTest
@testable import ParcelKeeper

final class PlatformPresentationTests: XCTestCase {
    private func shipment() -> Shipment {
        Shipment(trackingNumber: "SF123456789", carrierName: "顺丰速运", carrierCode: "sf")
    }

    func testOldShipmentKeepsLegacySourceAndDoesNotClaimRealtimeTracking() {
        let value = shipment()
        XCTAssertEqual(ShipmentRefreshPresentation.origin(value), "原UAPI／未关联")
        XCTAssertEqual(ShipmentRefreshPresentation.source(value), "未关联")
        let message = ShipmentRefreshPresentation.result(value, newlyDelivered: false)
        XCTAssertTrue(message.hasPrefix("物流已更新。"))
        XCTAssertTrue(message.contains("暂无物流轨迹"))
        XCTAssertTrue(message.contains("尚无成功查询"))
        XCTAssertFalse(message.contains("实时"))
    }

    func testPlatformOriginAndActualLogisticsSourceAreIndependent() {
        var value = shipment()
        value.originPlatform = "taobao"
        value.refreshChannel = "uapi"
        value.logisticsSource = "taobao"
        value.logisticsInfo = "包裹已到达转运中心"
        value.lastQueriedAt = Date(timeIntervalSince1970: 1_800_000_000)
        value.lastRefreshError = "登录已失效"
        XCTAssertEqual(ShipmentRefreshPresentation.origin(value), "淘宝")
        XCTAssertEqual(ShipmentRefreshPresentation.source(value), "淘宝")
        let message = ShipmentRefreshPresentation.result(value, newlyDelivered: true)
        XCTAssertTrue(message.hasPrefix("物流已更新，本次新增签收。"))
        XCTAssertTrue(message.contains("包裹已到达转运中心"))
        XCTAssertTrue(message.contains("来源：淘宝"))
        XCTAssertTrue(message.contains("上次成功："))
        XCTAssertTrue(message.contains("登录已失效"))
        XCTAssertEqual(value.carrierName, "顺丰速运")
    }

    func testLegacySuccessfulQueryIsLabelledUAPI() {
        var value = shipment()
        value.lastQueriedAt = Date()
        XCTAssertEqual(ShipmentRefreshPresentation.source(value), "原UAPI（旧记录）")
    }

    func testUnknownSourceIsNotInventedAsCarrierOrUAPI() {
        var value = shipment()
        value.originPlatform = "other"
        value.logisticsSource = "other"
        XCTAssertEqual(ShipmentRefreshPresentation.origin(value), "未关联（未知来源）")
        XCTAssertEqual(ShipmentRefreshPresentation.source(value), "未知来源")
    }

    func testShortcutChannelMappingAndOmittedParameterCompatibility() {
        XCTAssertEqual(QueryChannelChoice.automatic.mode, .automatic)
        XCTAssertEqual(QueryChannelChoice.platformOnly.mode, .platformOnly)
        XCTAssertEqual(QueryChannelChoice.uapi.mode, .uapi)
        XCTAssertEqual((nil as QueryChannelChoice?).resolvedMode, .automatic)
    }
}
