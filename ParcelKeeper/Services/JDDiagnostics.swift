import Foundation

/// Closed labels and bounded measurements only. Never retains the original error,
/// URL, response, credential or page text. Each user operation gets a random alias.
final class JDDiagnostics {
    let operation: UUID
    let log: DiagnosticLog
    let trace: DiagnosticTrace
    private let lock = NSLock()
    private var ended = false
    private var eventCounts: [DiagnosticEvent: Int] = [:]
    init(_ stage: DiagnosticStage, operation: UUID = UUID(), log: DiagnosticLog = .shared) {
        self.operation = operation; self.log = log
        trace = DiagnosticTrace(operation: operation, log: log)
        log.record(.jdOperationStarted, operation: operation, stage: stage)
        trace.begin(stage)
    }
    func begin(_ stage: DiagnosticStage) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        trace.begin(stage)
    }
    func event(_ event: DiagnosticEvent, reason: DiagnosticReason? = nil, counts: [DiagnosticMetric: Int] = [:]) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        // A broken page must not evict the final cause with a bridge-error flood.
        let count = eventCounts[event, default: 0]
        guard count < 20 else { return }
        eventCounts[event] = count + 1
        log.record(event, operation: operation, reason: reason, stage: trace.stage, counts: counts)
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }; ended = true
        trace.finish(); log.record(.jdOperationFinished, operation: operation)
    }
    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }; ended = true
        let stage = trace.stage ?? .preflight
        let reason: DiagnosticReason
        if stage == .jdSessionSave, (error as? MallWebError) == .authentication { reason = .storage }
        else if stage == .jdOrdersParse || stage == .jdLogisticsParse,
                (error as? MallWebError) == .unsupported { reason = .parse }
        else { reason = Self.reason(error) }
        trace.fail(JDLoggedError(reason: reason, stage: stage))
        var counts: [DiagnosticMetric: Int] = [:]
        if let code = Self.safeNetworkCode(error) { counts[.errorCode] = code }
        log.record(.jdOperationFailed, operation: operation, reason: reason, stage: stage, counts: counts)
    }
    static func reason(_ error: Error) -> DiagnosticReason {
        if let safe = error as? JDLoggedError { return safe.reason }
        return TrackingRefreshService.diagnosticReason(error)
    }
    static func safeNetworkCode(_ error: Error) -> Int? {
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return nil }
        // System-defined URL loading errors only; arbitrary integers are not identifiers.
        let allowed: Set<Int> = [-999, -1000, -1001, -1002, -1003, -1004, -1005, -1006,
                                 -1007, -1008, -1009, -1010, -1011, -1012, -1013, -1014,
                                 -1015, -1016, -1017, -1018, -1019, -1020, -1022,
                                 -1200, -1201, -1202, -1203, -1204, -1205, -1206, -2000]
        return allowed.contains(value.code) ? value.code : nil
    }
}

/// Safe context survives the client boundary; callers never need raw WebKit errors.
struct JDLoggedError: LocalizedError {
    let reason: DiagnosticReason
    let stage: DiagnosticStage
    var errorDescription: String? { "京东操作失败（阶段：\(stage.rawValue)，原因：\(reason.rawValue)），请在设置中导出诊断日志。" }
    var stopsBatch: Bool { reason == .authentication || reason == .verification }
}
