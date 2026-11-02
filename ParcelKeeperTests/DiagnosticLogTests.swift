import XCTest
@testable import ParcelKeeper

final class DiagnosticLogTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    private func log() -> DiagnosticLog { DiagnosticLog(directory: root) }

    func testMissingIsNotCorruptionAndRestartKeepsRecords() {
        let first = log()
        XCTAssertEqual(first.snapshotForTesting().status, .missing)
        first.record(.mallResponseAccepted, counts: [.rows: 3])
        let saved = first.snapshotForTesting()
        XCTAssertEqual(saved.status, .ready)
        XCTAssertEqual(saved.entryCount, 1)
        XCTAssertTrue(log().snapshotForTesting().text.contains("mallResponseAccepted"))
    }
    func testRotationAndMetricClamping() throws {
        let logger = log()
        for _ in 0..<550 {
            logger.record(.mallCollectionProgress, counts: [.rows: Int.max, .errorCode: Int.min, .httpStatus: 99999, .hasLink: 999])
        }
        let snapshot = logger.snapshotForTesting()
        XCTAssertEqual(snapshot.entryCount, 500)
        XCTAssertTrue(snapshot.text.contains("rows=2000000"))
        XCTAssertTrue(snapshot.text.contains("errorCode=-99999"))
        XCTAssertTrue(snapshot.text.contains("httpStatus=599"))
        XCTAssertTrue(snapshot.text.contains("hasLink=200"))
        let size = try Data(contentsOf: root.appendingPathComponent("diagnostics.json")).count
        XCTAssertLessThanOrEqual(size, DiagnosticLog.maximumBytes)
    }
    func testDisabledSurvivesRestartAndDoesNotRecord() {
        let logger = log()
        logger.setEnabled(false)
        logger.record(.appStarted)
        XCTAssertFalse(logger.snapshotForTesting().isEnabled)
        let restarted = log()
        restarted.record(.trackingStarted)
        XCTAssertEqual(restarted.snapshotForTesting().entryCount, 0)
        XCTAssertFalse(restarted.snapshotForTesting().isEnabled)
    }
    func testCorruptDoesNotSilentlyOverwriteAndClearRecovers() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("diagnostics.json")
        let damaged = Data("{private damaged content".utf8)
        try damaged.write(to: url)
        let logger = log()
        logger.record(.appStarted)
        XCTAssertEqual(logger.snapshotForTesting().status, .corrupt)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        XCTAssertFalse(logger.snapshotForTesting().text.contains("private damaged content"))
        logger.clear()
        XCTAssertEqual(logger.snapshotForTesting().status, .ready)
        XCTAssertEqual(logger.snapshotForTesting().entryCount, 0)
    }
    func testIOFailureIsNotMissing() throws {
        try Data("not a directory".utf8).write(to: root)
        let logger = log()
        XCTAssertEqual(logger.snapshotForTesting().status, .ioFailure)
        logger.record(.appStarted)
        XCTAssertEqual(logger.snapshotForTesting().status, .ioFailure)
    }
    func testConcurrentWritersAndOperationPseudonyms() {
        let logger = log()
        let supplied = UUID()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            logger.record(.mallFetchStarted, operation: supplied, reason: .network)
        }
        let snapshot = logger.snapshotForTesting()
        XCTAssertEqual(snapshot.entryCount, 100)
        XCTAssertFalse(snapshot.text.contains(supplied.uuidString))
        let operations = snapshot.text.split(separator: "\n").filter { $0.contains("operation=") }.compactMap {
            $0.components(separatedBy: "operation=").last?.components(separatedBy: " ").first
        }
        XCTAssertEqual(Set(operations).count, 1)
    }
    func testExportProtectionAndClearRemovesExports() throws {
        let logger = log()
        logger.record(.trackingFailed, reason: .network, counts: [.errorCode: -1009])
        _ = logger.snapshotForTesting()
        let exported = expectation(description: "export")
        var exportURL: URL?
        logger.export { result in
            switch result {
            case .success(let url): exportURL = url
            case .failure: XCTFail("export failed")
            }
            exported.fulfill()
        }
        wait(for: [exported], timeout: 5)
        let url = try XCTUnwrap(exportURL)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("trackingFailed"))
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #if targetEnvironment(simulator)
        // CoreSimulator may omit hardware-backed data protection metadata.
        // If it reports a value it must still be correct; device builds require it.
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        }
        #else
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        #endif
        logger.clear()
        XCTAssertEqual(logger.snapshotForTesting().entryCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testClearPreservesDisabledPreference() {
        let logger = log()
        logger.record(.appStarted)
        logger.setEnabled(false)
        logger.clear()
        let snapshot = logger.snapshotForTesting()
        XCTAssertFalse(snapshot.isEnabled)
        XCTAssertEqual(snapshot.entryCount, 0)
        XCTAssertFalse(log().snapshotForTesting().isEnabled)
    }
    func testRefreshAndToggleCallbacksRunOnMainQueue() {
        let logger = log()
        let done = expectation(description: "callbacks")
        logger.setEnabled(false) { updated in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(updated.isEnabled)
            logger.refresh { snapshot in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertFalse(snapshot.isEnabled)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
    }
    func testUnknownPersistedEventIsCorrupt() throws {
        let logger = log()
        logger.record(.appStarted)
        _ = logger.snapshotForTesting()
        let url = root.appendingPathComponent("diagnostics.json")
        let valid = try String(contentsOf: url, encoding: .utf8)
        let damaged = valid.replacingOccurrences(of: "appStarted", with: "private-arbitrary-payload")
        try Data(damaged.utf8).write(to: url)
        let snapshot = log().snapshotForTesting()
        XCTAssertEqual(snapshot.status, .corrupt)
        XCTAssertFalse(snapshot.text.contains("private-arbitrary-payload"))
    }
    func testOversizedFileIsCorruptNotLoaded() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 32, count: DiagnosticLog.maximumBytes + 1).write(to: root.appendingPathComponent("diagnostics.json"))
        XCTAssertEqual(log().snapshotForTesting().status, .corrupt)
    }
}
