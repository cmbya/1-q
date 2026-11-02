import XCTest
@testable import ParcelKeeper

final class PlatformRoutingTests: XCTestCase {
    final class PlatformClient: TaobaoTrackingQuerying {
        var calls = 0
        var failure: Error?
        var onQuery: (() throws -> Void)?
        func query(orderID: String, trackingNumber: String) async throws -> UAPITrackingResult {
            calls += 1
            try onQuery?()
            if let failure { throw failure }
            return UAPITrackingResult(trackingNumber: trackingNumber, carrierName: "淘宝承运商", carrierCode: "platform-code", status: .inTransit, logisticsInfo: "运输中", logisticsTime: nil, queryInfo: "平台轨迹", queriedAt: Date())
        }
    }
    var root: URL!
    var store: SharedPickupStore!
    var shipment: Shipment!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
        shipment = Shipment(trackingNumber: "YT1234567890123", carrierName: "圆通", carrierCode: "yto", note: "保留", pickupCode: "42")
        shipment.originPlatform = "taobao"
        shipment.taobaoOrderID = "123456789012345678"
        try store.transaction { data in
            data.shipments.append(shipment)
            data.records.append(PickupRecord(groupID: try XCTUnwrap(data.expressGroupID), code: "42", source: shipment.note, shipmentID: shipment.id))
        }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testAutomaticTaobaoDoesNotReadOrSavePhoneOrUseUAPI() async throws {
        let uapi = TrackingRefreshTests.Client(), platform = PlatformClient()
        let service = TrackingRefreshService(store: store, client: uapi, reloadWidgets: {}, taobaoClient: platform)
        // Invalid phone would fail validation if the Taobao route touched its storage.
        _ = try await service.refresh(id: shipment.id, phone: "not-a-phone")
        XCTAssertEqual(platform.calls, 1)
        XCTAssertEqual(uapi.calls, 0)
        let saved = try XCTUnwrap(store.snapshot().shipments.first)
        XCTAssertEqual(saved.logisticsSource, "taobao")
        XCTAssertNil(saved.uapiCarrierCode)
        XCTAssertNil(saved.lastRefreshError)
        XCTAssertEqual(saved.note, "保留")
    }
    func testMissingBindingFailsWithoutFallbackAndRetainsSuccessfulData() async throws {
        try store.transaction { $0.shipments[0].taobaoOrderID = nil; $0.shipments[0].logisticsInfo = "旧轨迹" }
        let uapi = TrackingRefreshTests.Client(), platform = PlatformClient()
        do { _ = try await TrackingRefreshService(store: store, client: uapi, reloadWidgets: {}, taobaoClient: platform).refresh(id: shipment.id); XCTFail() }
        catch { XCTAssertTrue(error is TaobaoTrackingError) }
        XCTAssertEqual(uapi.calls, 0)
        XCTAssertEqual(platform.calls, 0)
        let saved = try XCTUnwrap(store.snapshot().shipments.first)
        XCTAssertEqual(saved.logisticsInfo, "旧轨迹")
        XCTAssertNotNil(saved.lastRefreshError)
    }
    func testExplicitAndPersistedUAPIOverride() async throws {
        let uapi = TrackingRefreshTests.Client(), platform = PlatformClient()
        let service = TrackingRefreshService(store: store, client: uapi, reloadWidgets: {}, taobaoClient: platform)
        _ = try await service.refresh(id: shipment.id, mode: .uapi)
        try service.setRefreshChannel(id: shipment.id, channel: "uapi")
        _ = try await service.refresh(id: shipment.id)
        XCTAssertEqual(uapi.calls, 2)
        XCTAssertEqual(platform.calls, 0)
        XCTAssertEqual(try store.snapshot().shipments[0].logisticsSource, "uapi")
        try service.setRefreshChannel(id: shipment.id, channel: nil)
        XCTAssertNil(try store.snapshot().shipments[0].refreshChannel)
        XCTAssertThrowsError(try service.setRefreshChannel(id: shipment.id, channel: "taobao"))
    }
    func testLegacyAutomaticAndPlatformOnlySkip() async throws {
        try store.transaction { $0.shipments[0].originPlatform = nil; $0.shipments[0].taobaoOrderID = nil }
        let uapi = TrackingRefreshTests.Client(), platform = PlatformClient()
        let service = TrackingRefreshService(store: store, client: uapi, reloadWidgets: {}, taobaoClient: platform)
        let report = try await service.refreshPending(mode: .platformOnly)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(uapi.calls, 0)
        _ = try await service.refresh(id: shipment.id)
        XCTAssertEqual(uapi.calls, 1)
    }
    func testUnknownOriginIsNotSilentlyCharged() async throws {
        try store.transaction { $0.shipments[0].originPlatform = "other"; $0.shipments[0].taobaoOrderID = nil }
        let uapi = TrackingRefreshTests.Client()
        do { _ = try await TrackingRefreshService(store: store, client: uapi, reloadWidgets: {}).refresh(id: shipment.id); XCTFail() } catch {}
        XCTAssertEqual(uapi.calls, 0)
    }
    func testChangedBindingAndChannelRejectResultAndFailureMetadata() async throws {
        for changeChannel in [false, true] {
            let platform = PlatformClient(), uapi = TrackingRefreshTests.Client()
            try store.transaction { $0.shipments[0].refreshChannel = nil; $0.shipments[0].lastRefreshError = nil }
            platform.onQuery = { try self.store.transaction {
                if changeChannel { $0.shipments[0].refreshChannel = "uapi" }
                else { $0.shipments[0].taobaoOrderID = "999999999999999999" }
            } }
            do { _ = try await TrackingRefreshService(store: store, client: uapi, reloadWidgets: {}, taobaoClient: platform).refresh(id: shipment.id); XCTFail() } catch {}
            let saved = try XCTUnwrap(store.snapshot().shipments.first)
            XCTAssertNil(saved.queryInfo)
            XCTAssertNil(saved.lastRefreshError)
        }
    }
    func testAuthenticationStopsOnlyPlatformRequests() async throws {
        try store.transaction { data in
            for index in 1...2 {
                var other = self.shipment!
                other.id = UUID(); other.trackingNumber = "YT123456789012\(index)"
                if index == 2 { other.originPlatform = nil; other.taobaoOrderID = nil }
                other.lastQueryAttemptAt = Date(timeIntervalSince1970: Double(index))
                other.pickupCode = "extra-\(index)"
                data.shipments.append(other)
                data.records.append(PickupRecord(groupID: data.groups[0].id, code: other.pickupCode, source: other.note, shipmentID: other.id))
            }
        }
        let platform = PlatformClient(), uapi = TrackingRefreshTests.Client()
        platform.failure = TaobaoTrackingError.authentication
        let report = try await TrackingRefreshService(store: store, client: uapi, reloadWidgets: {}, taobaoClient: platform).refreshPending()
        XCTAssertEqual(platform.calls, 1)
        XCTAssertEqual(uapi.calls, 1)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.taobaoCount, 1)
        XCTAssertEqual(report.uapiCount, 1)
    }
    func testChannelSetterHonorsSharedQueryLease() throws {
        let lease = try store.acquireTrackingQuery(id: shipment.id)
        let service = TrackingRefreshService(store: store, client: TrackingRefreshTests.Client(), reloadWidgets: {})
        XCTAssertThrowsError(try service.setRefreshChannel(id: shipment.id, channel: "uapi"))
        XCTAssertNil(try store.snapshot().shipments[0].refreshChannel)
        lease.release()
        try service.setRefreshChannel(id: shipment.id, channel: "uapi")
        XCTAssertEqual(try store.snapshot().shipments[0].refreshChannel, "uapi")
    }
    func testPlatformOnlyIgnoresSavedUAPIOverride() async throws {
        try store.transaction { $0.shipments[0].refreshChannel = "uapi" }
        let uapi = TrackingRefreshTests.Client(), platform = PlatformClient()
        _ = try await TrackingRefreshService(store: store, client: uapi, reloadWidgets: {}, taobaoClient: platform).refresh(id: shipment.id, mode: .platformOnly)
        XCTAssertEqual(platform.calls, 1)
        XCTAssertEqual(uapi.calls, 0)
        XCTAssertEqual(try store.snapshot().shipments[0].refreshChannel, "uapi")
    }
    func testPlatformFailurePreservesLastSuccessAndOriginalException() async throws {
        try store.transaction {
            $0.shipments[0].queryInfo = "旧全文"
            $0.shipments[0].logisticsInfo = "旧节点"
            $0.shipments[0].logisticsSource = "uapi"
            $0.shipments[0].lastQueriedAt = Date(timeIntervalSince1970: 42)
        }
        let platform = PlatformClient()
        platform.failure = TaobaoTrackingError.verification
        do {
            _ = try await TrackingRefreshService(store: store, client: TrackingRefreshTests.Client(), reloadWidgets: {}, taobaoClient: platform).refresh(id: shipment.id)
            XCTFail()
        } catch TaobaoTrackingError.verification {} catch { XCTFail("Original error must be retained") }
        let saved = try XCTUnwrap(store.snapshot().shipments.first)
        XCTAssertEqual(saved.queryInfo, "旧全文")
        XCTAssertEqual(saved.logisticsInfo, "旧节点")
        XCTAssertEqual(saved.logisticsSource, "uapi")
        XCTAssertEqual(saved.lastQueriedAt, Date(timeIntervalSince1970: 42))
        XCTAssertNotNil(saved.lastRefreshError)
    }
    func testSanitizedFailureAndSuccessClearsError() async throws {
        let platform = PlatformClient(), uapi = TrackingRefreshTests.Client()
        let service = TrackingRefreshService(store: store, client: uapi, reloadWidgets: {}, taobaoClient: platform)
        platform.failure = NSError(domain: "secret phone=9876", code: 1)
        do { _ = try await service.refresh(id: shipment.id); XCTFail() } catch {}
        let message = try XCTUnwrap(store.snapshot().shipments[0].lastRefreshError)
        XCTAssertFalse(message.contains("secret")); XCTAssertFalse(message.contains("9876"))
        platform.failure = nil
        _ = try await service.refresh(id: shipment.id)
        XCTAssertNil(try store.snapshot().shipments[0].lastRefreshError)
    }
}
