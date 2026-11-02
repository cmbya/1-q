import XCTest
@testable import ParcelKeeper

final class MallCandidateBatchTests: XCTestCase {
    @MainActor func testOneTimeoutDoesNotLoseSuccessfulCandidates() async throws {
        let orders = try ["123456789", "123456790"].map { id in
            MallWebOrder(id: id, title: "fixture", url: try MallWebParser.detailURL(platform: .jd, orderID: id))
        }
        let result = try await MallCandidateBatch.collect(orders: orders) { order in
            if order.id == "123456789" { throw MallWebError.timeout }
            return MallWebDetail(number: "JD123456789", carrier: "京东", points: [])
        }
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.attempted, 2)
    }
    @MainActor func testAuthenticationStopsFurtherRequestsButKeepsEarlierResults() async throws {
        let orders = try ["123456789", "123456790", "123456791"].map { id in
            MallWebOrder(id: id, title: "fixture", url: try MallWebParser.detailURL(platform: .jd, orderID: id))
        }
        var calls = 0
        let result = try await MallCandidateBatch.collect(orders: orders) { _ in
            calls += 1
            if calls == 2 { throw MallWebError.authentication }
            return MallWebDetail(number: "JD123456789", carrier: "京东", points: [])
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.stopped, .authentication)
    }
    @MainActor func testDuplicateWaybillAcrossOrdersIsRejectedRatherThanBound() async throws {
        let orders = try ["123456789", "123456790"].map { id in
            MallWebOrder(id: id, title: "fixture", url: try MallWebParser.detailURL(platform: .jd, orderID: id))
        }
        let result = try await MallCandidateBatch.collect(orders: orders) { _ in
            MallWebDetail(number: "JD123456789", carrier: "京东", points: [])
        }
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.failed, 2)
    }
}
