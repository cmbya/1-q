import Foundation
import Security

// Independently implemented against zsdd2/kdyzm PROTOCOL.md at
// b13c0527cb38f3aad79cacf8ca85efacaa0004ed. No backend implementation is embedded.
enum KDYZMError: LocalizedError, Equatable {
    case origin, invalid, unauthorized, forbidden, pairing, rateLimited, network, keychain, alreadyBound, stale, queued, failed, empty, jobGone
    var errorDescription: String? {
        switch self {
        case .origin: return "请输入不带路径、凭据、查询或片段的 HTTPS 服务地址。"
        case .invalid: return "后台响应不受支持或身份冲突，未修改本地数据。"
        case .unauthorized: return "设备授权已失效，请先解绑后重新绑定。"
        case .forbidden: return "当前设备没有此记录的授权。"
        case .pairing: return "绑定码无效、已使用或已过期，请重新生成。"
        case .rateLimited: return "后台请求过于频繁，请稍后重试。"
        case .network: return "后台连接失败或超时，请检查地址和受信任的 HTTPS 证书。"
        case .keychain: return "设备钥匙串保存或回读失败，未确认本机绑定。若已兑换绑定码，后台可能已创建设备，请管理员撤销遗留设备后生成新码；不要重试原码。"
        case .alreadyBound: return "已绑定后台，请先明确解绑，不能直接更换。"
        case .stale: return "绑定或本地运单已变化，未采纳晚到结果。"
        case .queued: return "后台尚未完成（可能排队或冷却），未记为刷新成功；稍后刷新将继续查询任务。"
        case .failed: return "后台任务未成功，请在后台检查账号状态；已保留本地记录和轨迹。"
        case .empty: return "后台尚无这票的有效新轨迹，已保留上次结果。"
        case .jobGone: return "后台任务已过期或服务已重启，任务关联已清除；可再次手动刷新。"
        }
    }
    static func response(status: Int, code: String?) -> KDYZMError {
        // Never interpolate server message, response body, token or URL errors.
        if status == 401 || code == "DEVICE_UNAUTHORIZED" { return .unauthorized }
        if status == 403 { return .forbidden }
        if status == 429 { return .rateLimited }
        if code == "INVALID_PAIRING_CODE" { return .pairing }
        return .invalid
    }
    static func safe(_ error: Error) -> String {
        if let error = error as? KDYZMError { return error.localizedDescription }
        if error is CancellationError { return "操作已取消，未记为成功。" }
        return KDYZMError.network.localizedDescription
    }
}

struct KDYZMOrigin: Equatable {
    let value: String
    init(_ raw: String) throws {
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines), raw.utf8.count <= 2048,
              let c = URLComponents(string: raw), c.scheme == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", c.port.map({ $0 > 0 && $0 <= 65535 }) ?? true,
              !raw.contains("\\"), !raw.contains("%"), c.url != nil else { throw KDYZMError.origin }
        var normalized = c
        normalized.scheme = "https"; normalized.host = host.lowercased(); normalized.path = ""
        if normalized.port == 443 { normalized.port = nil }
        guard let value = normalized.url?.absoluteString else { throw KDYZMError.origin }
        self.value = value
    }
}

struct KDYZMCredential: Codable, Equatable {
    var baseURL: String
    var token: String
    var deviceID: String
    var generation: UUID
}
protocol KDYZMCredentialStore {
    func read() throws -> KDYZMCredential?
    func save(_ value: KDYZMCredential) throws
    func clear() throws
}
struct KDYZMKeychain: KDYZMCredentialStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.dinghao.ParcelKeeper.kdyzm.device.v1",
         kSecAttrAccount as String: "credential",
         kSecAttrSynchronizable as String: false]
    }
    func read() throws -> KDYZMCredential? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data,
              let value = try? JSONDecoder().decode(KDYZMCredential.self, from: bytes),
              (try? KDYZMOrigin(value.baseURL).value) == value.baseURL,
              KDYZMClient.validToken(value.token),
              !value.deviceID.isEmpty else { throw KDYZMError.keychain }
        return value
    }
    func save(_ value: KDYZMCredential) throws {
        let bytes = try JSONEncoder().encode(value)
        let attrs: [String: Any] = [kSecValueData as String: bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; attrs.forEach { q[$0.key] = $0.value }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw KDYZMError.keychain }
        } else if status != errSecSuccess { throw KDYZMError.keychain }
        guard try read() == value else { throw KDYZMError.keychain }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KDYZMError.keychain }
        guard try read() == nil else { throw KDYZMError.keychain }
    }
}

protocol KDYZMTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}
final class KDYZMHTTPS: NSObject, KDYZMTransport, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Reject every redirect, including same-origin redirects.
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = request.timeoutInterval
        config.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == request.url,
                  !(300...399).contains(http.statusCode),
                  http.expectedContentLength <= 2_000_000 else { throw KDYZMError.invalid }
            var bytes = Data(); bytes.reserveCapacity(8192)
            for try await byte in stream {
                try Task.checkCancellation()
                guard bytes.count < 2_000_000 else { throw KDYZMError.invalid }
                bytes.append(byte)
            }
            return (bytes, http.statusCode)
        } catch is CancellationError { throw CancellationError() }
        catch let error as KDYZMError { throw error }
        catch { throw KDYZMError.network }
    }
}

struct KDYZMFamily: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var accountCount: Int? = nil
}
struct KDYZMAccount: Codable, Equatable, Identifiable {
    var id: String
    var platform: String
    var label: String
    var familyId: String? = nil
    var familyName: String? = nil
    var status: String? = nil
}
struct KDYZMScope: Codable, Equatable {
    var familyIds: [String]?
    var legacyAccountIds: [String]?
    var families: [KDYZMFamily]
    var accountIds: [String]
    var accounts: [KDYZMAccount]
    var includeFutureAccounts: Bool
    func validated() throws -> Self {
        func unique(_ ids: [String]) throws {
            guard Set(ids).count == ids.count else { throw KDYZMError.invalid }
            for id in ids { _ = try KDYZMClient.segment(id) }
        }
        try unique(accountIds); try unique(accounts.map(\.id)); try unique(families.map(\.id))
        try unique(familyIds ?? []); try unique(legacyAccountIds ?? [])
        guard Set(accountIds) == Set(accounts.map(\.id)) else { throw KDYZMError.invalid }
        if let familyIds {
            guard Set(families.map(\.id)) == Set(familyIds), accounts.allSatisfy({
                familyIds.contains($0.familyId ?? "") || (legacyAccountIds ?? []).contains($0.id)
            }) else { throw KDYZMError.invalid }
        }
        return self
    }
}
struct KDYZMPreview: Decodable {
    struct Service: Decodable { var name: String; var baseUrl: String }
    var service: Service
    var scope: KDYZMScope
    var expiresAt: Double
}
struct KDYZMRedeemed: Decodable {
    var token: String
    var deviceId: String
    var accounts: [KDYZMAccount]
    var familyIds: [String]?
    var legacyAccountIds: [String]?
    var families: [KDYZMFamily]?
}
private struct KDYZMErrorEnvelope: Decodable {
    struct Failure: Decodable { var code: String }
    var error: Failure
}
struct KDYZMClient {
    var transport: any KDYZMTransport = KDYZMHTTPS()
    func request<T: Decodable>(_ type: T.Type, origin: String, path: String, method: String = "GET",
                                body: [String: String]? = nil, credential: KDYZMCredential? = nil,
                                status: Int = 200, timeout: TimeInterval = 12) async throws -> T {
        guard timeout.isFinite, timeout > 0 else { throw KDYZMError.queued }
        let base = try KDYZMOrigin(origin)
        guard path.hasPrefix("/v1/"), !path.contains("?"), !path.contains("#"), !path.contains(".."),
              let url = URL(string: base.value + path), url.host == URL(string: base.value)?.host else { throw KDYZMError.invalid }
        if let credential { guard credential.baseURL == base.value else { throw KDYZMError.stale } }
        var req = URLRequest(url: url); req.httpMethod = method; req.timeoutInterval = min(12, timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let credential { req.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization") }
        let (bytes, actual) = try await transport.send(req)
        guard bytes.count <= 2_000_000 else { throw KDYZMError.invalid }
        guard actual == status else {
            if actual == 404 && path.hasPrefix("/v1/sync-jobs/") { throw KDYZMError.jobGone }
            let code = (try? JSONDecoder().decode(KDYZMErrorEnvelope.self, from: bytes))?.error.code
            throw KDYZMError.response(status: actual, code: code)
        }
        do { return try JSONDecoder().decode(type, from: bytes) }
        catch { throw KDYZMError.invalid }
    }
    func preview(origin: String, code: String) async throws -> KDYZMPreview {
        guard !code.isEmpty, code.utf8.count <= 80 else { throw KDYZMError.pairing }
        let preview = try await request(KDYZMPreview.self, origin: origin, path: "/v1/pairing-codes/preview", method: "POST", body: ["code": code])
        guard try KDYZMOrigin(preview.service.baseUrl) == KDYZMOrigin(origin),
              let expiry = try KDYZMTime.date(preview.expiresAt), expiry > Date() else { throw KDYZMError.invalid }
        _ = try preview.scope.validated()
        return preview
    }
    func snapshot(_ credential: KDYZMCredential, timeout: TimeInterval = 12) async throws -> KDYZMSnapshot {
        let result = try await request(KDYZMSnapshot.self, origin: credential.baseURL, path: "/v1/snapshot", credential: credential, timeout: timeout)
        return try result.validated()
    }
    static func validToken(_ raw: String) -> Bool {
        raw.utf8.count <= 280 && raw.range(of: #"\Apcd_[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil
    }
    static func segment(_ raw: String) throws -> String {
        guard !raw.isEmpty, raw.utf8.count <= 256,
              raw.range(of: #"\A[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil else { throw KDYZMError.invalid }
        return raw
    }
}

// Serializes binding changes and local commit generation checks in this process.
// AppIntents are hosted in the main app; the widget only reads value-only models.
actor KDYZMConnection {
    static let shared = KDYZMConnection()
    let keys: any KDYZMCredentialStore
    let client: KDYZMClient
    private var changing = false
    private var refreshing = Set<UUID>()
    func beginRefresh(_ id: UUID) throws {
        guard !changing, refreshing.insert(id).inserted else { throw PickupStorageError.queryInProgress }
    }
    func endRefresh(_ id: UUID) { refreshing.remove(id) }
    init(keys: any KDYZMCredentialStore = KDYZMKeychain(), client: KDYZMClient = KDYZMClient()) {
        self.keys = keys; self.client = client
    }
    func credential() throws -> KDYZMCredential {
        guard !changing, let value = try keys.read() else { throw KDYZMError.unauthorized }
        return value
    }
    func current() throws -> KDYZMCredential? { try keys.read() }
    func verify(_ expected: KDYZMCredential) throws {
        guard !changing, try keys.read() == expected else { throw KDYZMError.stale }
    }
    func commit<T>(_ expected: KDYZMCredential, body: () throws -> T) throws -> T {
        try verify(expected)
        return try body() // no await between generation verification and transaction
    }
    func bind(origin: String, code: String, preview: KDYZMPreview, deviceName: String) async throws {
        guard !changing, try keys.read() == nil else { throw KDYZMError.alreadyBound }
        guard try KDYZMOrigin(origin).value == KDYZMOrigin(preview.service.baseUrl).value,
              let expiry = try KDYZMTime.date(preview.expiresAt), expiry > Date() else { throw KDYZMError.pairing }
        _ = try preview.scope.validated()
        changing = true; defer { changing = false }
        let value = try await client.request(KDYZMRedeemed.self, origin: origin, path: "/v1/devices", method: "POST", body: ["code": code, "deviceName": deviceName], status: 201)
        guard KDYZMClient.validToken(value.token),
              !value.deviceId.isEmpty else { throw KDYZMError.invalid }
        guard Set(value.familyIds ?? []) == Set(preview.scope.familyIds ?? []),
              Set(value.legacyAccountIds ?? []) == Set(preview.scope.legacyAccountIds ?? []) else { throw KDYZMError.invalid }
        if preview.scope.familyIds == nil {
            guard Set(value.accounts.map(\.id)) == Set(preview.scope.accountIds) else { throw KDYZMError.invalid }
        }
        do {
            try keys.save(KDYZMCredential(baseURL: try KDYZMOrigin(origin).value, token: value.token, deviceID: value.deviceId, generation: UUID()))
        } catch { throw KDYZMError.keychain } // Remote redemption cannot be rolled back locally; never retry the code.
    }
    func unbind(localOnly: Bool = false) async throws {
        guard !changing, let current = try keys.read() else { throw KDYZMError.unauthorized }
        changing = true; defer { changing = false }
        if !localOnly {
            struct Revoked: Decodable { var revoked: Bool }
            do {
                let result = try await client.request(Revoked.self, origin: current.baseURL, path: "/v1/devices/current", method: "DELETE", credential: current)
                guard result.revoked else { throw KDYZMError.invalid }
            } catch KDYZMError.unauthorized { /* already revoked: verify below */ }
            do {
                _ = try await client.snapshot(current)
                throw KDYZMError.invalid
            } catch KDYZMError.unauthorized { /* read-back proof of revocation */ }
        }
        guard try keys.read() == current else { throw KDYZMError.stale }
        try keys.clear()
    }
}
