import Foundation

struct UAPITrackingResult {
    let trackingNumber: String
    let carrierName: String
    let carrierCode: String
    let status: ShipmentStatus?
    let logisticsInfo: String
    let logisticsTime: Date?
    let queryInfo: String
    let queriedAt: Date
}

enum UAPIError: LocalizedError, Equatable {
    case notConfigured, privacyConsentRequired, authentication, quota
    case rateLimited(Double?)
    case noData, invalidResponse, invalidPhone, invalidTrackingNumber, invalidKey, keychain, unavailable, cancelled

    var stopsBatch: Bool {
        switch self {
        case .notConfigured, .privacyConsentRequired, .authentication, .quota, .rateLimited, .keychain, .cancelled, .unavailable: return true
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
        }
    }
}

/// Only the opt-in flag enters preferences. Credentials use a separate, device-only
/// Keychain service (the existing AIKeychainStore never syncs or backs up its item).
final class UAPISettingsService {
    private let defaults: UserDefaults
    private let keys: any AIKeyStore
    private static let lock = NSRecursiveLock()
    private let enabledKey = "uapi.enabled"

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
    }
    func hasKey() throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try storedKey() != nil
    }
    func saveKey(_ key: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validKey(value) else { throw UAPIError.invalidKey }
        do { try keys.save(value) } catch { throw UAPIError.keychain }
    }
    func removeKey() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        do { try keys.delete() } catch { throw UAPIError.keychain }
        defaults.set(false, forKey: enabledKey)
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
    fileprivate func requestKey() throws -> String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard isEnabled(), let key = try storedKey() else { throw UAPIError.notConfigured }
        return key
    }
}

protocol UAPITrackingQuerying {
    func query(trackingNumber: String, carrierCode: String?, phone: String?, refresh: Bool) async throws -> UAPITrackingResult
}

final class UAPITrackingClient: UAPITrackingQuerying {
    private let settings: UAPISettingsService
    private let network: any AINetworking
    init(settings: UAPISettingsService = UAPISettingsService(), network: any AINetworking = AISecureNetwork()) {
        self.settings = settings
        self.network = network
    }
    func query(trackingNumber: String, carrierCode: String?, phone: String?, refresh: Bool) async throws -> UAPITrackingResult {
        do {
            try Task.checkCancellation()
            let key = try settings.requestKey()
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
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // Exactly one charged request. AISecureNetwork refuses all redirects.
            let (data, response) = try await network.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw UAPIError.invalidResponse }
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
            return try payload.result(expectedNumber: trackingNumber, queriedAt: Date())
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
            // Explicit completion wins only if other explicit fields do not deny it.
            if is_completed == true, let mapped, mapped != .delivered { throw UAPIError.invalidResponse }
            if is_completed == false, mapped == .delivered { throw UAPIError.invalidResponse }
            let pickup = status.map { ["待取件", "待领取", "等待取件"].contains($0) } ?? false
            if is_completed == true && pickup { throw UAPIError.invalidResponse }
            let explicitPending = status.map { ["待揽收", "已揽收", "运输中", "派送中", "待取件", "待领取", "等待取件", "异常"].contains($0) } ?? false
            if (is_completed == true || mapped == .delivered) && explicitPending { throw UAPIError.invalidResponse }
            let chineseCompletion = status.map { ["已签收", "已妥投", "已完成"].contains($0) } ?? false
            if chineseCompletion && (is_completed == false || mapped.map { $0 != .delivered } == true) { throw UAPIError.invalidResponse }
            if mapped == .delivered && pickup { throw UAPIError.invalidResponse }
            let state: ShipmentStatus? = (is_completed == true || chineseCompletion) ? .delivered : (pickup ? .readyForPickup : mapped)
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
