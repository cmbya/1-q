import Foundation
import Darwin
import CryptoKit

/// 历史兼容：仅供旧缓存测试及 ShipmentPhoneStore 的尾号退休/失效流程使用。
/// UAPI/Tmini 查询不再调用 identity/lookup/store，不读取或删除历史缓存文件。
/// mutatePhone 只做设备私有 Keychain 删除/回读；不访问缓存目录或锁，兼容退休日志。
enum PaidTrackingCacheError: LocalizedError {
    case unavailable
    var errorDescription: String? { "本地付费查询缓存无法安全读取或保存；未自动重试，请在 App 检查缓存文件。" }
}

final class PaidTrackingCache {
    struct Identity: Codable, Equatable {
        let channel: String
        let number: String
        let carrier: String
        let generation: String
        let phoneToken: String
    }
    private struct Entry: Codable {
        let identity: Identity
        let startedAt: Date
        var result: UAPITrackingResult
    }
    private let directory: URL?
    private let phoneKeys: (String) -> any AIKeyStore
    init(directory: URL? = nil, phoneKeys: @escaping (String) -> any AIKeyStore = { AIKeychainStore(service: $0) }) {
        self.directory = directory; self.phoneKeys = phoneKeys
    }
    private func locked<T>(_ body: (URL) throws -> T) throws -> T {
        do {
            let root: URL
            if let directory { root = directory }
            else { root = try AppGroupResolver.container().appendingPathComponent("PaidTrackingCache", isDirectory: true) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var excluded = root
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let fd = open(root.appendingPathComponent("cache.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw PaidTrackingCacheError.unavailable }
            defer { close(fd) }
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard [EWOULDBLOCK, EAGAIN, EINTR].contains(errno), ProcessInfo.processInfo.systemUptime < deadline else { throw PaidTrackingCacheError.unavailable }
                Thread.sleep(forTimeInterval: 0.01)
            }
            defer { flock(fd, LOCK_UN) }
            return try body(root.appendingPathComponent("success-v1.json"))
        } catch { throw PaidTrackingCacheError.unavailable }
    }
    /// Tail digits live only in the device-only Keychain, never in the file or a low-entropy hash.
    /// Rotating the random token on any change prevents A -> B -> A reviving an old identity.
    func identity(channel: String, number: String, carrier: String = "", generation: String, phone: String? = nil) throws -> Identity {
        try locked { _ in
            var token = "none"
            if channel == "uapi" {
                let context = Data(number.utf8)
                let name = SHA256.hash(data: context).map { String(format: "%02x", $0) }.joined()
                let keys = phoneKeys("ParcelKeeper.PaidTrackingPhone." + name)
                let prefix = generation + "\n" + (phone ?? "") + "\n"
                if let saved = try keys.read(), saved.hasPrefix(prefix), let uuid = UUID(uuidString: String(saved.dropFirst(prefix.count))) {
                    token = uuid.uuidString
                } else {
                    token = UUID().uuidString
                    let value = prefix + token
                    try keys.save(value)
                    guard try keys.read() == value else { throw PaidTrackingCacheError.unavailable }
                }
            }
            return Identity(channel: channel, number: number, carrier: carrier, generation: generation, phoneToken: token)
        }
    }
    /// Legacy Keychain cleanup only: never opens/creates/deletes cache files or locks.
    /// Retire the corresponding number's device-only secret BEFORE any phone mutation.
    /// Callers own the tracking lease; delete/import journals retry on failure or crash.
    func mutatePhone(number: String, mutation: () throws -> Void) throws {
        let name = SHA256.hash(data: Data(number.utf8)).map { String(format: "%02x", $0) }.joined()
        let keys = phoneKeys("ParcelKeeper.PaidTrackingPhone." + name)
        try keys.delete()
        guard try keys.read() == nil else { throw PaidTrackingCacheError.unavailable }
        try mutation()
    }
    private func validateIdentity(_ identity: Identity) throws {
        guard identity.channel == "uapi" else { return }
        let context = Data(identity.number.utf8)
        let name = SHA256.hash(data: context).map { String(format: "%02x", $0) }.joined()
        guard let saved = try phoneKeys("ParcelKeeper.PaidTrackingPhone." + name).read(),
              saved.hasPrefix(identity.generation + "\n"),
              saved.hasSuffix("\n" + identity.phoneToken) else { throw PaidTrackingCacheError.unavailable }
    }
    private func read(_ url: URL) throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 8_000_000 else { throw PaidTrackingCacheError.unavailable }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
        guard entries.count <= 256, entries.allSatisfy({
            $0.identity.number == $0.result.trackingNumber && !$0.result.queryInfo.isEmpty &&
            $0.result.queryInfo.count <= 10000 && $0.startedAt <= $0.result.queriedAt &&
            $0.startedAt.timeIntervalSince1970.isFinite && $0.result.queriedAt.timeIntervalSince1970.isFinite
        }) else { throw PaidTrackingCacheError.unavailable }
        return entries
    }
    static func isFresh(_ result: UAPITrackingResult, now: Date) -> Bool {
        let age = now.timeIntervalSince(result.queriedAt)
        let ttl: TimeInterval
        switch result.status {
        case .delivered: ttl = 604800
        case .outForDelivery: ttl = 1800
        case .readyForPickup: ttl = 21600
        default: ttl = 7200
        }
        return age >= 0 && age < ttl
    }
    func lookup(_ identity: Identity, now: Date = Date()) throws -> UAPITrackingResult? {
        try locked { url in
            try validateIdentity(identity)
            guard var result = try read(url).first(where: { $0.identity == identity })?.result,
                  Self.isFresh(result, now: now) else { return nil }
            result.isCached = true
            return result
        }
    }
    func store(_ result: UAPITrackingResult, identity: Identity, startedAt: Date, now: Date = Date()) throws {
        try locked { url in
            try validateIdentity(identity)
            var entries = try read(url)
            guard result.trackingNumber == identity.number, startedAt <= result.queriedAt,
                  Self.isFresh(result, now: now) else { return }
            if entries.contains(where: { $0.identity == identity && ($0.startedAt > startedAt || $0.result.queriedAt > result.queriedAt) }) { return }
            entries.removeAll { $0.identity == identity || !Self.isFresh($0.result, now: now) }
            var saved = result; saved.isCached = false
            entries.append(Entry(identity: identity, startedAt: startedAt, result: saved))
            entries.sort { $0.result.queriedAt > $1.result.queriedAt }
            entries = Array(entries.prefix(256))
            let data = try JSONEncoder().encode(entries)
            guard data.count <= 8_000_000 else { throw PaidTrackingCacheError.unavailable }
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
