import XCTest
@testable import ParcelKeeper

final class JDDiagnosticsTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func testResponseFailureReasonsRemainDistinctAndContainNoRawPayload() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(directory: root)
        for reason in [DiagnosticReason.responseDecode, .responseSchema, .scriptProcessing] {
            let operation = JDDiagnostics(.jdOrdersParse, log: log)
            operation.fail(JDLoggedError(reason: reason, stage: .jdOrdersParse))
            let encoded = try JSONEncoder().encode(reason)
            XCTAssertEqual(try JSONDecoder().decode(DiagnosticReason.self, from: encoded), reason)
        }
        let text = log.snapshotForTesting().text
        for value in ["reason=responseDecode", "reason=responseSchema", "reason=scriptProcessing"] {
            XCTAssertTrue(text.contains(value))
        }
        XCTAssertFalse(text.contains("reason=unsupported"))
        XCTAssertFalse(text.contains("https:"))
    }
    func testJDFilterMetricsStayClosedAndBounded() {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(directory: root)
        log.record(.jdResponseAccepted, stage: .jdOrdersParse,
            counts: [.jdMissingDate: 9, .jdBusinessExcluded: 1, .jdOutsideWindow: -1,
                     .jdDetailFailed: Int.max, .jdWithoutWaybill: 0, .jdLimited: 9])
        let text = log.snapshotForTesting().text
        for expected in ["jdMissingDate=9", "jdBusinessExcluded=1", "jdOutsideWindow=0",
                         "jdDetailFailed=2000000", "jdWithoutWaybill=0", "jdLimited=1"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        XCTAssertEqual(DiagnosticMetric.jdLimited.bounded(-5), 0)
    }
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
    func testConcurrentEventFloodAndTerminationRemainBounded() {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(directory: root)
        let operation = JDDiagnostics(.jdQuery, log: log)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in operation.event(.jdBridgeRejected, reason: .envelope) }
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index.isMultiple(of: 2) { operation.finish() }
            else { operation.fail(MallWebError.authentication) }
            operation.begin(.jdOrdersParse)
        }
        let lines = log.snapshotForTesting().text.components(separatedBy: "\n")
        XCTAssertEqual(lines.filter { $0.contains("jdBridgeRejected") }.count, 20)
        XCTAssertEqual(lines.filter { $0.contains("jdOperationFinished") || $0.contains("jdOperationFailed") }.count, 1)
        XCTAssertNil(operation.trace.stage)
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
