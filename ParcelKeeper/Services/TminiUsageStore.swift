import Foundation
import Darwin

/// Local dispatch estimate, not a receipt or platform balance. No keys or shipment identifiers.
struct TminiUsageSummary: Codable, Equatable {
    var queries: Int64 = 0
    var firstRecordedAt: Date?
    var lastRecordedAt: Date?
    var points: Int64 { queries * 4 }
}

final class TminiUsageStore {
    private let directory: URL?
    init(directory: URL? = nil) { self.directory = directory }

    private func locked<T>(_ body: (URL) throws -> T) throws -> T {
        let root: URL
        if let directory { root = directory }
        else { root = try AppGroupResolver.container().appendingPathComponent("ParcelKeeper", isDirectory: true) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent("tmini-usage.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw TminiError.accounting }
        defer { close(fd) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard [EWOULDBLOCK, EAGAIN, EINTR].contains(errno), ProcessInfo.processInfo.systemUptime < deadline else { throw TminiError.accounting }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { flock(fd, LOCK_UN) }
        return try body(root.appendingPathComponent("tmini-usage.json"))
    }
    private func read(_ url: URL) throws -> TminiUsageSummary {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return TminiUsageSummary() }
        let value = try JSONDecoder().decode(TminiUsageSummary.self, from: data)
        guard value.queries >= 0, value.queries <= Int64.max / 4,
              (value.queries == 0 && value.firstRecordedAt == nil && value.lastRecordedAt == nil) ||
              (value.queries > 0 && value.firstRecordedAt != nil && value.lastRecordedAt != nil) else { throw TminiError.accounting }
        return value
    }
    func summary() throws -> TminiUsageSummary { try locked { try read($0) } }
    /// Persist before dispatch so even timeouts/cancellation have one attempt entry.
    /// If persistence fails, do not dispatch an unaccounted request.
    func recordDispatch(now: Date = Date()) throws {
        do {
            try locked { url in
                var value = try read(url)
                guard value.queries < Int64.max / 4 else { throw TminiError.accounting }
                value.queries += 1
                if value.firstRecordedAt == nil { value.firstRecordedAt = now }
                value.lastRecordedAt = now
                try JSONEncoder().encode(value).write(to: url, options: .atomic)
            }
        } catch { throw TminiError.accounting }
    }
}
