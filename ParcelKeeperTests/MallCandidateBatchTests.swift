// Legacy direct marketplace import is opt-in; source is retained for restoration.
#if ENABLE_DIRECT_MALL_IMPORT
import XCTest
@testable import ParcelKeeper

final class MallCandidateBatchTests: XCTestCase {
    @MainActor func testAttemptBudgetCanReachUsefulOrderAfterEightFailures() async throws {
        let orders = (0..<30).map { MallWebOrder(id: "261103-" + String(123456 + $0), title: "fixture", url: MallPlatform.pdd.ordersURL) }
        var calls = 0
        let result = try await MallCandidateBatch.collect(orders: orders) { _ in
            calls += 1
            if calls <= 8 { throw MallWebError.noTrace }
            return MallWebDetail(number: "YT" + String(123456 + calls), carrier: "圆通", points: [])
        }
        XCTAssertEqual(calls, 16)
        XCTAssertEqual(result.candidates.count, 8)
        XCTAssertEqual(result.failed, 8)
    }
    @MainActor func testOneTimeoutDoesNotLoseSuccessfulCandidates() async throws {
        let orders = try ["123456789", "123456790"].map { id in
            MallWebOrder(id: id, title: "fixture", url: try MallWebParser.detailURL(platform: .pdd, orderID: "261103-" + id))
        }
        let result = try await MallCandidateBatch.collect(orders: orders) { order in
            if order.id == "123456789" { throw MallWebError.timeout }
            return MallWebDetail(number: "YT123456789", carrier: "圆通", points: [])
        }
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.attempted, 2)
    }
    @MainActor func testAuthenticationStopsFurtherRequestsButKeepsEarlierResults() async throws {
        let orders = try ["123456789", "123456790", "123456791"].map { id in
            MallWebOrder(id: id, title: "fixture", url: try MallWebParser.detailURL(platform: .pdd, orderID: "261103-" + id))
        }
        var calls = 0
        let result = try await MallCandidateBatch.collect(orders: orders) { _ in
            calls += 1
            if calls == 2 { throw MallWebError.authentication }
            return MallWebDetail(number: "YT123456789", carrier: "圆通", points: [])
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.stopped, .authentication)
    }
    @MainActor func testDuplicateWaybillAcrossOrdersIsRejectedRatherThanBound() async throws {
        let orders = try ["123456789", "123456790"].map { id in
            MallWebOrder(id: id, title: "fixture", url: try MallWebParser.detailURL(platform: .pdd, orderID: "261103-" + id))
        }
        let result = try await MallCandidateBatch.collect(orders: orders) { _ in
            MallWebDetail(number: "YT123456789", carrier: "圆通", points: [])
        }
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.failed, 2)
    }
}
#endif
