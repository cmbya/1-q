import Foundation

// This allowlist is the entire payload API. Never add messages, URLs, cookies,
// order/tracking identifiers, request bodies, or localized error descriptions.
enum DiagnosticEvent: String, Codable, CaseIterable {
    case appStarted, mallFetchStarted, mallFetchFinished, mallFetchFailed
    case mallPageLoad, mallPageFinished, mallNavigationRejected, mallNavigationFailed
    case mallProcessTerminated, mallBridgeRejected, mallResponseRejected, mallResponseAccepted
    case mallScriptReady, mallScriptFailed, mallCollectionProgress, mallCollectionFinished
    case mallDetailStarted, mallDetailFinished, mallTimeout
    case trackingStarted, trackingFinished, trackingFailed
}

enum DiagnosticReason: String, Codable, CaseIterable {
    case frame, generation, envelope, url, interface, ownership, limit
    case authentication, verification, identity, noTrace, timeout, unsupported
    case cancelled, network, storage, unknown
}

enum DiagnosticMetric: String, Codable, CaseIterable {
    case rows, candidates, responses, bytes, httpStatus, errorCode, round
    case hasProgress, hasType, hasLink, hasDate, accepted, rejected

    // Numeric fields are measurements only, never identifiers. Even accidental
    // large numbers cannot preserve phone/order/tracking identifiers verbatim.
    func bounded(_ value: Int) -> Int {
        switch self {
        case .hasProgress, .hasType, .hasLink, .hasDate: return min(200, max(0, value))
        case .httpStatus: return min(599, max(0, value))
        case .errorCode: return min(99_999, max(-99_999, value))
        case .round: return min(1_000, max(0, value))
        default: return min(2_000_000, max(0, value))
        }
    }
}

enum DiagnosticLogStatus: String { case missing, ready, corrupt, ioFailure }
enum DiagnosticLogIssue: Error, Equatable { case read, write, export, clear }

struct DiagnosticLogSnapshot {
    let status: DiagnosticLogStatus
    let issue: DiagnosticLogIssue?
    let isEnabled: Bool
    let entryCount: Int
    let text: String
}

final class DiagnosticLog {
    static let shared = DiagnosticLog()
    static let maximumEntries = 500
    static let maximumBytes = 512 * 1024

    private struct Entry: Codable {
        let timestamp: Date
        let event: DiagnosticEvent
        let operation: UUID?
        let reason: DiagnosticReason?
        let counts: [DiagnosticMetric: Int]
    }
    private struct Archive: Codable {
        var schema = 1
        var enabled = true
        var entries: [Entry] = []
    }

    private let queue = DispatchQueue(label: "ParcelKeeper.private-diagnostics", qos: .utility)
    private let fileManager = FileManager.default
    private let directory: URL?
    private var fileURL: URL? { directory?.appendingPathComponent("diagnostics.json") }
    private var exportDirectory: URL? { directory?.appendingPathComponent("Exports", isDirectory: true) }
    private var archive = Archive()
    private var loaded = false
    private var status: DiagnosticLogStatus = .missing
    private var issue: DiagnosticLogIssue?
    // Callers' UUIDs are never persisted. A bounded, in-memory mapping gives each
    // operation a fresh random pseudonym; it is not an installation identifier.
    private var operationAliases: [UUID: UUID] = [:]
    private var operationOrder: [UUID] = []

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("PrivateDiagnostics", isDirectory: true)
    }

    func record(_ event: DiagnosticEvent, operation: UUID? = nil, reason: DiagnosticReason? = nil, counts: [DiagnosticMetric: Int] = [:]) {
        let timestamp = Date()
        queue.async {
            self.loadIfNeeded()
            guard self.archive.enabled, self.status == .ready || self.status == .missing else { return }
            var bounded: [DiagnosticMetric: Int] = [:]
            for (key, value) in counts { bounded[key] = key.bounded(value) }
            let alias = operation.map { self.alias(for: $0) }
            self.archive.entries.append(Entry(timestamp: timestamp, event: event, operation: alias, reason: reason, counts: bounded))
            if self.archive.entries.count > Self.maximumEntries {
                self.archive.entries.removeFirst(self.archive.entries.count - Self.maximumEntries)
            }
            do { try self.persist() } catch { self.status = .ioFailure; self.issue = .write }
        }
    }

    // All completion callbacks are delivered on the main queue. No UI thread disk I/O.
    func refresh(_ completion: @escaping (DiagnosticLogSnapshot) -> Void) {
        queue.async {
            if self.status == .ioFailure {
                if self.issue == .read {
                    self.loaded = false
                } else if self.issue == .write {
                    do { try self.persist() } catch { self.issue = .write }
                }
            }
            self.loadIfNeeded()
            let snapshot = self.makeSnapshot()
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    func setEnabled(_ enabled: Bool, completion: ((DiagnosticLogSnapshot) -> Void)? = nil) {
        queue.async {
            self.loadIfNeeded()
            if self.status == .ready || self.status == .missing {
                let previous = self.archive.enabled
                self.archive.enabled = enabled
                do { try self.persist() }
                catch { self.archive.enabled = previous; self.status = .ioFailure; self.issue = .write }
            }
            let snapshot = self.makeSnapshot()
            DispatchQueue.main.async { completion?(snapshot) }
        }
    }

    func clear(completion: ((DiagnosticLogSnapshot) -> Void)? = nil) {
        queue.async {
            self.loadIfNeeded()
            do {
                guard let fileURL = self.fileURL, let exportDirectory = self.exportDirectory else { throw DiagnosticLogIssue.clear }
                // Delete managed exports first. A partial deletion is an explicit error.
                if self.fileManager.fileExists(atPath: exportDirectory.path) {
                    try self.fileManager.removeItem(at: exportDirectory)
                }
                if self.fileManager.fileExists(atPath: fileURL.path) { try self.fileManager.removeItem(at: fileURL) }
                self.archive.entries.removeAll()
                self.operationAliases.removeAll()
                self.operationOrder.removeAll()
                try self.persist()
            } catch { self.status = .ioFailure; self.issue = .clear }
            let snapshot = self.makeSnapshot()
            DispatchQueue.main.async { completion?(snapshot) }
        }
    }

    func export(_ completion: @escaping (Result<URL, DiagnosticLogIssue>) -> Void) {
        queue.async {
            self.loadIfNeeded()
            let result: Result<URL, DiagnosticLogIssue>
            do {
                guard self.status == .ready || self.status == .missing,
                      let directory = self.directory, let exportDirectory = self.exportDirectory else { throw DiagnosticLogIssue.export }
                try self.prepareDirectory(directory)
                try self.prepareDirectory(exportDirectory)
                let url = exportDirectory.appendingPathComponent("diagnostics.txt")
                let data = Data(self.makeSnapshot().text.utf8)
                guard data.count <= Self.maximumBytes else { throw DiagnosticLogIssue.export }
                try self.protectedWrite(data, to: url)
                self.issue = nil
                result = .success(url)
            } catch { self.issue = .export; result = .failure(.export) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // Queue barrier for deterministic XCTest only. UI must use refresh instead.
    func snapshotForTesting() -> DiagnosticLogSnapshot {
        queue.sync { loadIfNeeded(); return makeSnapshot() }
    }

    private func alias(for supplied: UUID) -> UUID {
        if let value = operationAliases[supplied] { return value }
        if operationOrder.count >= Self.maximumEntries {
            operationAliases.removeValue(forKey: operationOrder.removeFirst())
        }
        let value = UUID()
        operationAliases[supplied] = value
        operationOrder.append(supplied)
        return value
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL else { status = .ioFailure; issue = .read; return }
        do {
            if let directory {
                do {
                    let parent = try fileManager.attributesOfItem(atPath: directory.path)
                    guard parent[.type] as? FileAttributeType == .typeDirectory else {
                        status = .ioFailure; issue = .read; return
                    }
                } catch {
                    let failure = error as NSError
                    guard failure.domain == NSCocoaErrorDomain && failure.code == NSFileNoSuchFileError else { throw error }
                }
            }
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? Self.maximumBytes + 1
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  fileSize <= Self.maximumBytes else { status = .corrupt; return }
            let data = try Data(contentsOf: fileURL)
            guard data.count <= Self.maximumBytes else { status = .corrupt; return }
            let decoded: Archive
            do { decoded = try JSONDecoder().decode(Archive.self, from: data) }
            catch { status = .corrupt; return }
            guard decoded.schema == 1, decoded.entries.count <= Self.maximumEntries,
                  decoded.entries.allSatisfy({ entry in
                      entry.timestamp.timeIntervalSince1970.isFinite &&
                      entry.timestamp.timeIntervalSince1970 >= 0 &&
                      entry.timestamp.timeIntervalSince1970 <= 253_402_300_799 &&
                      entry.counts.allSatisfy { $0.key.bounded($0.value) == $0.value }
                  }) else { status = .corrupt; return }
            archive = decoded
            status = .ready
            issue = nil
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                status = .missing
                issue = nil
            } else { status = .ioFailure; issue = .read }
        }
    }

    private func prepareDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try protect(url)
    }

    private func protect(_ url: URL) throws {
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
        // Explicitly request and verify the resource flag rather than relying on inheritance.
        guard try mutableURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw DiagnosticLogIssue.write
        }
    }

    private func protectedWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try protect(url)
    }

    private func persist() throws {
        guard let directory, let fileURL else { throw DiagnosticLogIssue.write }
        try prepareDirectory(directory)
        var data = try JSONEncoder().encode(archive)
        while data.count > Self.maximumBytes && !archive.entries.isEmpty {
            archive.entries.removeFirst()
            data = try JSONEncoder().encode(archive)
        }
        guard data.count <= Self.maximumBytes else { throw DiagnosticLogIssue.write }
        try protectedWrite(data, to: fileURL)
        status = .ready
        issue = nil
    }

    private func safeVersion(_ value: Any?) -> String {
        guard let value = value as? String, !value.isEmpty, value.count <= 32,
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || $0.value == 46 }) else { return "unknown" }
        return value
    }

    private func makeSnapshot() -> DiagnosticLogSnapshot {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = safeVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString"))
        let build = safeVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion"))
        var lines = ["ParcelKeeper local diagnostics schema=1", "app=\(version) build=\(build) iOS=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                     "status=\(status.rawValue) enabled=\(archive.enabled) entries=\(archive.entries.count)",
                     "Only allowlisted events, bounded measurements and random operation aliases. No account or device identifier."]
        let formatter = ISO8601DateFormatter()
        for entry in archive.entries {
            var line = "\(formatter.string(from: entry.timestamp)) \(entry.event.rawValue)"
            if let operation = entry.operation { line += " operation=\(operation.uuidString)" }
            if let reason = entry.reason { line += " reason=\(reason.rawValue)" }
            for key in entry.counts.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                if let value = entry.counts[key] { line += " \(key.rawValue)=\(value)" }
            }
            lines.append(line)
        }
        return DiagnosticLogSnapshot(status: status, issue: issue, isEnabled: archive.enabled,
                                     entryCount: archive.entries.count, text: lines.joined(separator: "\n"))
    }
}
