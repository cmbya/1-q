import XCTest
@testable import ParcelKeeper

final class JDDiagnosticsTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func testNetworkCodesDoNotRetainErrorTextOrFailingURL() {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(directory: root)
        let operation = JDDiagnostics(.jdOrdersPage, log: log)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "synthetic-cookie-secret", NSURLErrorFailingURLStringErrorKey: "https://example.com/?key=synthetic-cookie-secret"])
        operation.fail(error)
        let text = log.snapshotForTesting().text
        XCTAssertTrue(text.contains("reason=timeout stage=jdOrdersPage"))
        XCTAssertTrue(text.contains("errorCode=-1001"))
        XCTAssertFalse(text.contains("synthetic-cookie-secret"))
        XCTAssertFalse(text.contains("https://"))
        XCTAssertNil(JDDiagnostics.safeNetworkCode(NSError(domain: "untrusted", code: -1001)))
        XCTAssertNil(JDDiagnostics.safeNetworkCode(NSError(domain: NSURLErrorDomain, code: 123456789)))
    }
    func testParseAndSaveHaveSpecificSafeReasons() {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(directory: root)
        let parse = JDDiagnostics(.jdOrdersParse, log: log)
        parse.fail(MallWebError.unsupported)
        let save = JDDiagnostics(.jdSessionSave, log: log)
        save.fail(MallWebError.authentication)
        let text = log.snapshotForTesting().text
        XCTAssertTrue(text.contains("reason=parse stage=jdOrdersParse"))
        XCTAssertTrue(text.contains("reason=storage stage=jdSessionSave"))
    }
    func testDuplicateTerminationAndEventFloodAreBounded() {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(directory: root)
        let operation = JDDiagnostics(.jdQuery, log: log)
        for _ in 0..<100 { operation.event(.jdBridgeRejected, reason: .envelope) }
        operation.fail(MallWebError.identityMismatch)
        operation.finish(); operation.fail(CancellationError())
        let text = log.snapshotForTesting().text
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.contains("jdBridgeRejected") }.count, 20)
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.contains("jdOperationFailed") }.count, 1)
        XCTAssertFalse(text.contains("jdOperationFinished"))
    }
    func testClientPreflightFailureActuallyWritesDiagnostic() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(directory: root)
        do {
            _ = try await JDInAppClient(cookies: [], diagnosticLog: log).query(orderID: "bad", trackingNumber: "bad")
            XCTFail("Invalid identifiers must fail before opening WebKit")
        } catch { XCTAssertEqual(error as? MallWebError, .identityMismatch) }
        let text = log.snapshotForTesting().text
        XCTAssertTrue(text.contains("jdOperationStarted"))
        XCTAssertTrue(text.contains("jdOperationFailed"))
        XCTAssertTrue(text.contains("reason=identity stage=jdQuery"))
    }
}
