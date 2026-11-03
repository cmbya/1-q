import Foundation

struct UAPITrackingResult: Codable {
    let trackingNumber: String
    let carrierName: String
    let carrierCode: String
    let status: ShipmentStatus?
    let logisticsInfo: String
    let logisticsTime: Date?
    let queryInfo: String
    let queriedAt: Date
    var isCached: Bool = false
}

enum UAPIError: LocalizedError, Equatable {
    case notConfigured, privacyConsentRequired, authentication, quota
    case rateLimited(Double?)
    case noData, invalidResponse, invalidPhone, invalidTrackingNumber, invalidKey, keychain, unavailable, cancelled, configurationChanged

    var stopsBatch: Bool {
        switch self {
        case .notConfigured, .privacyConsentRequired, .authentication, .quota, .rateLimited, .keychain, .cancelled, .configurationChanged: return true
        default: return false
        }
    }
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先开启 UAPI 并保存 API Key。"
        case .privacyConsentRequired: return "开启前请确认：运单号及可选手机尾号将发送至 uapis.cn；每次查询消耗 40 credits。"
        case .authentication: return "UAPI 认证失败，请检查 API Key。"
        case .quota: return "UAPI 额度不足，已停止批量查询。"
        case .rateLimited: return "UAPI 请求过于频繁，已停止批量查询，请稍后手动重试。"
        case .noData: return "UAPI 暂无这票快递的物流轨迹。"
        case .invalidResponse: return "UAPI 返回的物流数据无效，未更新快递。"
        case .invalidPhone: return "手机尾号必须是四位数字。"
        case .invalidTrackingNumber: return "运单号格式无效。"
        case .invalidKey: return "API Key 不能为空或包含空白、控制字符。"
        case .keychain: return "无法访问 UAPI 的 Keychain 凭据。"
        case .unavailable: return "UAPI 服务或网络暂不可用，未自动重试。"
        case .cancelled: return "UAPI 查询已取消。"
        case .configurationChanged: return "UAPI 配置已更改，未保存晚到结果，请手动重新查询。"
        }
    }
}

/// A timestamped server snapshot, not a locally decremented or realtime balance.
struct UAPIUsageSnapshot: Codable, Equatable {
    let remainingCredits: Int?
    let chargedCredits: Int?
    let updatedAt: Date
    let requestStartedAt: Date

    init?(response: HTTPURLResponse, requestStartedAt: Date = Date()) {
        func integer(_ raw: String) -> Int? {
            let value = raw.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(value)
        }
        let buckets = (response.value(forHTTPHeaderField: "RateLimit") ?? "").split(separator: ",")
        let quota = buckets.filter { $0.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "\"billing-quota\"" }
        var remaining: Int?
        if quota.count == 1 {
            let fields = quota[0].split(separator: ";").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            let values = fields.filter { $0.hasPrefix("r=") }
            let units = fields.filter { $0.hasPrefix("uapi-unit=") }
            if values.count == 1, units == ["uapi-unit=\"credits\""] {
                remaining = integer(String(values[0].dropFirst(2)))
            }
        }
        let charged = response.value(forHTTPHeaderField: "UAPI-Credits-Charged").flatMap(integer)
        guard remaining != nil || charged != nil else { return nil }
        self.remainingCredits = remaining
        self.chargedCredits = charged
        self.updatedAt = Date()
        self.requestStartedAt = requestStartedAt
    }
}

/// Opaque, non-Codable commit token. Never contains an API key.
struct UAPIConfiguration: Equatable {
    fileprivate let generation: String
}

/// Only opt-in and non-secret usage snapshots enter preferences. Credentials use
/// the isolated device-only Keychain service, never results, UI or backups.
final class UAPISettingsService {
    private let defaults: UserDefaults
    private let keys: any AIKeyStore
    private static let lock = NSRecursiveLock()
    private let enabledKey = "uapi.enabled"
    private let usageKey = "uapi.usage"
    private let generationKey = "uapi.usageGeneration"

    func usageSnapshot() -> UAPIUsageSnapshot? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let data = defaults.data(forKey: usageKey) else { return nil }
        return try? JSONDecoder().decode(UAPIUsageSnapshot.self, from: data)
    }
    func usageGeneration() -> String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let value = defaults.string(forKey: generationKey) { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: generationKey)
        return value
    }
    func recordUsage(_ response: HTTPURLResponse, generation: String, requestStartedAt: Date = Date()) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard generation == usageGeneration(),
              let snapshot = UAPIUsageSnapshot(response: response, requestStartedAt: requestStartedAt),
              usageSnapshot().map({ $0.requestStartedAt <= requestStartedAt }) ?? true,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: usageKey)
    }
    private func resetUsage() {
        defaults.removeObject(forKey: usageKey)
        defaults.set(UUID().uuidString, forKey: generationKey)
    }

    init(defaults: UserDefaults = .standard, keys: any AIKeyStore = AIKeychainStore(service: "ParcelKeeper.UAPI")) {
        self.defaults = defaults
        self.keys = keys
    }
    func isEnabled() -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return defaults.bool(forKey: enabledKey)
    }
    func setEnabled(_ enabled: Bool, privacyConfirmed: Bool = false) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if enabled && !isEnabled() && !privacyConfirmed { throw UAPIError.privacyConsentRequired }
        defaults.set(enabled, forKey: enabledKey)
        defaults.set(UUID().uuidString, forKey: generationKey)
    }
    func hasKey() throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try storedKey() != nil
    }
    func saveKey(_ key: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validKey(value) else { throw UAPIError.invalidKey }
        resetUsage()
        do {
            try keys.save(value)
            guard try keys.read() == value else { throw UAPIError.keychain }
        } catch { defaults.set(false, forKey: enabledKey); throw UAPIError.keychain }
    }
    func removeKey() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        resetUsage()
        defaults.set(false, forKey: enabledKey)
        do { try keys.delete() } catch { throw UAPIError.keychain }
    }
    private static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 4096 && key.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
    }
    private func storedKey() throws -> String? {
        let value: String?
        do { value = try keys.read() } catch { throw UAPIError.keychain }
        guard let value, Self.validKey(value) else { return nil }
        return value
    }
    // Intentionally not exposed by settings/UI or included in any result/backup.
    fileprivate func requestCredential() throws -> (key: String, generation: String) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard isEnabled(), let key = try storedKey() else { throw UAPIError.notConfigured }
        return (key, usageGeneration())
    }
    fileprivate func validateCredential(_ credential: (key: String, generation: String)) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try withConfiguration(UAPIConfiguration(generation: credential.generation)) {
            guard try storedKey() == credential.key else { throw UAPIError.configurationChanged }
        }
    }
    func configurationToken() throws -> UAPIConfiguration {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard isEnabled(), try storedKey() != nil else { throw UAPIError.notConfigured }
        return UAPIConfiguration(generation: usageGeneration())
    }
    func validateConfiguration(_ token: UAPIConfiguration) throws {
        try withConfiguration(token) {}
    }
    /// Same lock as key/enabled changes; held only across a synchronous local commit.
    func withConfiguration<T>(_ token: UAPIConfiguration, operation: () throws -> T) throws -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard isEnabled(), token.generation == usageGeneration(), try storedKey() != nil else {
            throw UAPIError.configurationChanged
        }
        return try operation()
    }
}

protocol UAPITrackingQuerying {
    func configurationToken() throws -> UAPIConfiguration?
    func withConfiguration<T>(_ token: UAPIConfiguration, operation: () throws -> T) throws -> T
    func query(trackingNumber: String, carrierCode: String?, phone: String?, refresh: Bool) async throws -> UAPITrackingResult
}

// Legacy/synthetic injected clients have no settings authority. Production overrides
// these protocol requirements, so existential dispatch uses the atomic guard.
extension UAPITrackingQuerying {
    func configurationToken() throws -> UAPIConfiguration? { nil }
    func withConfiguration<T>(_ token: UAPIConfiguration, operation: () throws -> T) throws -> T { try operation() }
}

final class UAPITrackingClient: UAPITrackingQuerying {
    private let settings: UAPISettingsService
    private let network: any AINetworking
    // Legacy injection labels are ignored; queries never access historical cache storage.
    init(settings: UAPISettingsService = UAPISettingsService(), network: any AINetworking = UAPIBoundedNetwork(), cache _: PaidTrackingCache? = nil, ignoreCache _: Bool = false) {
        self.settings = settings
        self.network = network
    }
    func configurationToken() throws -> UAPIConfiguration? { try settings.configurationToken() }
    func withConfiguration<T>(_ token: UAPIConfiguration, operation: () throws -> T) throws -> T {
        try settings.withConfiguration(token, operation: operation)
    }
    func query(trackingNumber: String, carrierCode: String?, phone: String?, refresh: Bool) async throws -> UAPITrackingResult {
        do {
            try Task.checkCancellation()
            let credential = try settings.requestCredential()
            // Validate, never repair a supplied identifier before dispatch.
            guard (try? ShipmentShortcutParser.number(trackingNumber)) == trackingNumber else { throw UAPIError.invalidTrackingNumber }
            if let phone, phone.utf8.count != 4 || !phone.utf8.allSatisfy({ (48...57).contains($0) }) { throw UAPIError.invalidPhone }
            var components = URLComponents(string: "https://uapis.cn/api/v1/misc/tracking/query")!
            var items = [URLQueryItem(name: "tracking_number", value: trackingNumber)]
            if let carrierCode, !carrierCode.isEmpty { items.append(URLQueryItem(name: "carrier_code", value: carrierCode)) }
            if let phone { items.append(URLQueryItem(name: "phone", value: phone)) }
            items.append(URLQueryItem(name: "refresh", value: refresh ? "true" : "false"))
            components.queryItems = items
            guard let url = components.url else { throw UAPIError.invalidTrackingNumber }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            request.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // One request attempt; UAPIBoundedNetwork bounds bytes and refuses redirects.
            let startedAt = Date()
            try settings.validateCredential(credential)
            let (data, response) = try await network.data(for: request)
            try settings.validateCredential(credential)
            guard let http = response as? HTTPURLResponse else { throw UAPIError.invalidResponse }
            // Billing headers remain useful even on quota errors or invalid logistics bodies.
            settings.recordUsage(http, generation: credential.generation, requestStartedAt: startedAt)
            try Task.checkCancellation()
            switch http.statusCode {
            case 200: break
            case 204, 404: throw UAPIError.noData
            case 401, 403: throw UAPIError.authentication
            case 402: throw UAPIError.quota
            case 429: throw UAPIError.rateLimited(Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
            case 500...599: throw UAPIError.unavailable
            default: throw UAPIError.invalidResponse
            }
            guard data.count <= 2_000_000 else { throw UAPIError.invalidResponse }
            let payload: Response
            do { payload = try JSONDecoder().decode(Response.self, from: data) }
            catch { throw UAPIError.invalidResponse }
            let result = try payload.result(expectedNumber: trackingNumber, queriedAt: Date())
            // Do not persist a server echo of credentials or the phone tail.
            func safe(_ text: String) -> String {
                var value = text.replacingOccurrences(of: credential.key, with: "[已隐藏]")
                if let phone { value = value.replacingOccurrences(of: phone, with: "[已隐藏]") }
                return value
            }
            let sanitized = UAPITrackingResult(trackingNumber: result.trackingNumber, carrierName: safe(result.carrierName), carrierCode: safe(result.carrierCode), status: result.status, logisticsInfo: safe(result.logisticsInfo), logisticsTime: result.logisticsTime, queryInfo: safe(result.queryInfo), queriedAt: result.queriedAt)
            try settings.validateCredential(credential)
            return sanitized
        } catch is CancellationError { throw UAPIError.cancelled }
        catch let error as UAPIError { throw error }
        catch let error as URLError where error.code == .cancelled { throw UAPIError.cancelled }
        catch { throw UAPIError.unavailable }
    }
    private static func retryDelay(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(text), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text).map { max(0, $0.timeIntervalSinceNow) }
    }
    private struct Response: Decodable {
        struct Track: Decodable { let time: String; let context: String }
        let tracking_number: String
        let carrier_code: String?
        let carrier_name: String?
        let track_count: Int?
        let is_completed: Bool?
        let completed_at: String?
        let status: String?
        let status_code: String?
        let tracks: [Track]

        func result(expectedNumber: String, queriedAt: Date) throws -> UAPITrackingResult {
            guard tracking_number == expectedNumber else { throw UAPIError.invalidResponse }
            guard !tracks.isEmpty else { throw UAPIError.noData }
            if let count = track_count, count != tracks.count { throw UAPIError.invalidResponse }
            if let completed_at, !completed_at.isEmpty, ShipmentShortcutParser.date(completed_at) == nil { throw UAPIError.invalidResponse }
            let dated = try tracks.map { track -> (track: Track, date: Date) in
                guard !track.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let date = ShipmentShortcutParser.date(track.time) else { throw UAPIError.invalidResponse }
                return (track, date)
            }.sorted { $0.date > $1.date }
            let latest = dated[0]
            if dated.dropFirst().contains(where: { $0.date == latest.date && $0.track.context != latest.track.context }) { throw UAPIError.invalidResponse }
            let mapped: ShipmentStatus?
            switch status_code {
            case "pending", "picked_up", "in_transit": mapped = .inTransit
            case "out_for_delivery": mapped = .outForDelivery
            case "delivered": mapped = .delivered
            case "exception": mapped = .exception
            default: mapped = nil
            }
            // A validated newest recipient-collection fact corrects coarse status fields,
            // including stale is_completed=false. Identity, dates/count and tie guards above
            // remain mandatory. Generic/agent signatures and instructions never override.
            let collected = MallDeliveryState.recipientCollected(latest: latest.track.context)
            let pickup = status.map { ["待取件", "待领取", "等待取件"].contains($0) } ?? false
            let explicitPending = status.map { ["待揽收", "已揽收", "运输中", "派送中", "待取件", "待领取", "等待取件", "异常"].contains($0) } ?? false
            let chineseCompletion = status.map { ["已签收", "已妥投", "已完成"].contains($0) } ?? false
            // Without narrow actual collection evidence, conflicting fields still fail closed.
            if !collected {
                if is_completed == true, let mapped, mapped != .delivered { throw UAPIError.invalidResponse }
                if is_completed == false, mapped == .delivered { throw UAPIError.invalidResponse }
                if is_completed == true && pickup { throw UAPIError.invalidResponse }
                if (is_completed == true || mapped == .delivered) && explicitPending { throw UAPIError.invalidResponse }
                if chineseCompletion && (is_completed == false || mapped.map { $0 != .delivered } == true) { throw UAPIError.invalidResponse }
                if mapped == .delivered && pickup { throw UAPIError.invalidResponse }
            }
            let state: ShipmentStatus? = collected ? .delivered : ((is_completed == true || chineseCompletion) ? .delivered : (pickup ? .readyForPickup : mapped))
            let name = carrier_name ?? ""
            let code = carrier_code ?? ""
            let history = dated.map { "\($0.track.time) \($0.track.context)" }.joined(separator: "\n")
            let info = "查询来源：UAPI (uapis.cn)\n快递单号：\(tracking_number)\n快递公司：\(name)\n当前状态：\(state?.rawValue ?? status ?? "未知")\n物流轨迹：\n\(history)"
            guard info.count <= 10000, name.count <= 100, code.count <= 100 else { throw UAPIError.invalidResponse }
            return UAPITrackingResult(trackingNumber: tracking_number, carrierName: name, carrierCode: code, status: state,
                                      logisticsInfo: latest.track.context, logisticsTime: latest.date, queryInfo: info, queriedAt: queriedAt)
        }
    }
}
