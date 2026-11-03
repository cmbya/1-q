import Foundation
import CoreFoundation

/// Fixed messages only: GET credentials can be present in transport errors and server replies.
enum TminiError: Error, LocalizedError, Equatable {
    case notConfigured, consent, invalidKey, keychain, authentication, quota, rateLimited
    case maintenance, noData, invalidResponse, invalidNumber, unavailable, cancelled, configurationChanged, accounting
    var stopsBatch: Bool {
        switch self {
        case .notConfigured, .consent, .invalidKey, .keychain, .authentication, .quota, .rateLimited, .maintenance, .cancelled, .configurationChanged, .accounting: return true
        default: return false
        }
    }
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先在设置中保存密钥并启用 Tmini。"
        case .consent: return "启用前请确认 Tmini 的收费 GET 查询与隐私说明。"
        case .invalidKey: return "Tmini 密钥格式无效，不得包含空白或控制字符。"
        case .keychain: return "Tmini 本机钥匙串保存或回读失败。"
        case .authentication: return "Tmini 密钥无效、停用或过期，请检查控制台；本轮停止该渠道。"
        case .quota: return "Tmini 余额或调用额度不足；本轮停止该渠道。"
        case .rateLimited: return "Tmini 调用受限；本轮停止该渠道，不自动重试。"
        case .maintenance: return "Tmini 服务维护或不可用；本轮停止该渠道。"
        case .noData: return "Tmini 暂无可用轨迹，保留已有物流。"
        case .invalidResponse: return "Tmini 返回数据无效，未更新快递。"
        case .invalidNumber: return "Tmini 查询运单号格式无效。"
        case .unavailable: return "Tmini 网络或服务不可用，未自动重试。"
        case .cancelled: return "Tmini 查询已取消。"
        case .configurationChanged: return "Tmini 配置已更改，未保存晚到结果，请手动重新查询。"
        case .accounting: return "Tmini 本地记账失败，未发送新的查询；已有记账未清空。"
        }
    }
    static func server(_ code: Int) -> TminiError {
        switch code {
        case 11005: return .rateLimited
        case 11004, 11024: return .quota
        case 11001, 11002, 11003, 11011, 11012, 11019, 11020, 11023: return .authentication
        case 11006...11010, 11013...11018, 11021, 11022: return .maintenance
        default: return .invalidResponse
        }
    }
}

/// Never Codable or persisted; the key stays in Keychain or request-scoped memory.
struct TminiConfiguration: Equatable {
    fileprivate let key: String
    fileprivate let generation: String
}
final class TminiSettingsService {
    private static let lock = NSRecursiveLock()
    private let defaults: UserDefaults
    private let keys: any AIKeyStore
    init(defaults: UserDefaults = .standard, keys: any AIKeyStore = AIKeychainStore(service: "ParcelKeeper.Tmini")) {
        self.defaults = defaults; self.keys = keys
    }
    func isEnabled() -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return defaults.bool(forKey: "tmini.enabled")
    }
    func setEnabled(_ value: Bool, privacyConfirmed: Bool = false) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if value && !isEnabled() && !privacyConfirmed { throw TminiError.consent }
        defaults.set(value, forKey: "tmini.enabled")
        defaults.set(UUID().uuidString, forKey: "tmini.generation")
    }
    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }
    private func storedKey() throws -> String? {
        do {
            guard let key = try keys.read(), Self.valid(key) else { return nil }
            return key
        } catch { throw TminiError.keychain }
    }
    func hasKey() throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try storedKey() != nil
    }
    func saveKey(_ key: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard Self.valid(key) else { throw TminiError.invalidKey }
        // Invalidate in-flight queries even when save/readback fails.
        defaults.set(UUID().uuidString, forKey: "tmini.generation")
        do {
            try keys.save(key)
            guard try keys.read() == key else { throw TminiError.keychain }
        } catch { defaults.set(false, forKey: "tmini.enabled"); throw TminiError.keychain }
    }
    func removeKey() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        defaults.set(false, forKey: "tmini.enabled")
        defaults.set(UUID().uuidString, forKey: "tmini.generation")
        do {
            try keys.delete()
            guard try keys.read() == nil else { throw TminiError.keychain }
        } catch { throw TminiError.keychain }
    }
    func configurationToken() throws -> TminiConfiguration {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard isEnabled(), let key = try storedKey() else { throw TminiError.notConfigured }
        if defaults.string(forKey: "tmini.generation") == nil { defaults.set(UUID().uuidString, forKey: "tmini.generation") }
        return TminiConfiguration(key: key, generation: defaults.string(forKey: "tmini.generation")!)
    }
    func validateConfiguration(_ token: TminiConfiguration) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard (try? configurationToken()) == token else { throw TminiError.configurationChanged }
    }
}

protocol TminiTrackingQuerying {
    func configurationToken() throws -> TminiConfiguration
    func validateConfiguration(_ token: TminiConfiguration) throws
    func query(trackingNumber: String) async throws -> UAPITrackingResult
}

/// One GET, no redirects, ordinary system TLS trust, ephemeral session without cookies/cache.
/// URLSession bytes are bounded during reception rather than after buffering the response.
final class TminiSecureNetwork: AINetworking {
    private let delegate = AIRedirectGuard()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= 2_000_000 else { bytes.task.cancel(); throw TminiError.invalidResponse }
        var body = Data()
        do {
            for try await byte in bytes {
                guard body.count < 2_000_000 else { throw TminiError.invalidResponse }
                body.append(byte)
            }
        } catch { bytes.task.cancel(); throw error }
        return (body, response)
    }
}

final class TminiTrackingClient: TminiTrackingQuerying {
    private let settings: TminiSettingsService
    private let network: any AINetworking
    private let usage: TminiUsageStore
    // Legacy injection labels are ignored; every valid query dispatches one paid request.
    init(settings: TminiSettingsService = TminiSettingsService(), network: any AINetworking = TminiSecureNetwork(), usage: TminiUsageStore = TminiUsageStore(), cache _: PaidTrackingCache? = nil, ignoreCache _: Bool = false) {
        self.settings = settings; self.network = network; self.usage = usage
    }
    func configurationToken() throws -> TminiConfiguration { try settings.configurationToken() }
    func validateConfiguration(_ token: TminiConfiguration) throws { try settings.validateConfiguration(token) }
    func query(trackingNumber: String) async throws -> UAPITrackingResult {
        do {
            try Task.checkCancellation()
            guard (try? ShipmentShortcutParser.number(trackingNumber)) == trackingNumber else { throw TminiError.invalidNumber }
            let token = try configurationToken()
            var components = URLComponents(string: "https://api.tmini.net/apis/autonumber")!
            components.queryItems = [URLQueryItem(name: "key", value: token.key), URLQueryItem(name: "trackingNo", value: trackingNumber)]
            guard let url = components.url else { throw TminiError.invalidNumber }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            try Task.checkCancellation()
            try validateConfiguration(token)
            try usage.recordDispatch()
            let (data, response) = try await network.data(for: request)
            try Task.checkCancellation()
            try validateConfiguration(token)
            guard let http = response as? HTTPURLResponse else { throw TminiError.invalidResponse }
            switch http.statusCode {
            case 200: break
            case 401, 403: throw TminiError.authentication
            case 402: throw TminiError.quota
            case 429: throw TminiError.rateLimited
            case 500...599: throw TminiError.maintenance
            default: throw TminiError.invalidResponse
            }
            let result = try Self.parse(data, expectedNumber: trackingNumber, secret: token.key)
            try validateConfiguration(token)
            return result
        } catch is CancellationError { throw TminiError.cancelled }
        catch let error as TminiError { throw error }
        catch let error as URLError where error.code == .cancelled { throw TminiError.cancelled }
        catch { throw TminiError.unavailable }
    }
    static func parse(_ data: Data, expectedNumber: String, secret: String? = nil) throws -> UAPITrackingResult {
        guard data.count <= 2_000_000, (try? ShipmentShortcutParser.number(expectedNumber)) == expectedNumber else { throw TminiError.invalidResponse }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw TminiError.invalidResponse }
        if let error = root["errcode"] {
            if let n = error as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == Double(n.intValue) { throw TminiError.server(n.intValue) }
            if let s = error as? String, let n = Int(s) { throw TminiError.server(n) }
            throw TminiError.invalidResponse
        }
        guard root["code"] as? String == "0000000000",
              let envelope = root["data"] as? [String: Any],
              let service = envelope["serviceCode"] as? NSNumber,
              CFGetTypeID(service) != CFBooleanGetTypeID(), service.doubleValue == 0,
              let packages = envelope["packageInfoList"] as? [[String: Any]], packages.count == 1,
              let package = packages.first, package["trackingNo"] as? String == expectedNumber else { throw TminiError.invalidResponse }
        func text(_ field: String, limit: Int) throws -> String {
            guard let value = package[field] else { return "" }
            guard let value = value as? String, value.count <= limit,
                  !value.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }) else { throw TminiError.invalidResponse }
            return value
        }
        func date(_ raw: String) -> Date? {
            // Only documented compact time and standard second-resolution detail time.
            for format in ["yyyyMMddHHmmss", "yyyy-MM-dd HH:mm:ss"] {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(identifier: "Asia/Shanghai")
                f.dateFormat = format; f.isLenient = false
                if let d = f.date(from: raw), f.string(from: d) == raw { return d }
            }
            return nil
        }
        var events: [(time: Date, text: String)] = []
        if let value = package["trackingDetails"], !(value is NSNull) {
            guard let details = value as? [[String: Any]] else { throw TminiError.invalidResponse }
            for detail in details {
                guard let raw = detail["time"] as? String, let time = date(raw),
                      let context = detail["context"] as? String,
                      !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, context.count <= 10000 else { throw TminiError.invalidResponse }
                events.append((time, context))
            }
        }
        let operateTime = try text("operateTime", limit: 32)
        let operateMessage = try text("operateMessage", limit: 10000)
        if !operateTime.isEmpty || !operateMessage.isEmpty {
            guard let time = date(operateTime), !operateMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TminiError.invalidResponse }
            events.append((time, operateMessage))
        }
        events.sort { $0.time > $1.time }
        guard let latest = events.first else { throw TminiError.noData }
        guard !events.dropFirst().contains(where: { $0.time == latest.time && $0.text != latest.text }) else { throw TminiError.invalidResponse }
        let name = try text("cpName", limit: 100)
        let carrier = try text("cp", limit: 100)
        let state = try text("state", limit: 100)
        // signFlag AUTOMATIC is not proof of delivery. Only the newest actual event is classified.
        let status = MallDeliveryState.resolve(latest: latest.text) ?? (state == "TRANSPORT" ? ShipmentStatus.inTransit : nil)
        var lines = ["查询来源：Tmini (api.tmini.net)", "快递单号：\(expectedNumber)", "快递公司：\(name)", "接口状态：\(state)", "物流轨迹："]
        lines += events.map { ShipmentDateDisplay.string($0.time) + " " + $0.text }
        for field in ["getcode", "address", "onboxTime"] {
            let value = try text(field, limit: 1000)
            if !value.isEmpty { lines.append("\(field)（接口说明，未自动写入个人字段）：\(value)") }
        }
        if let value = package["cabinetLocation"], !(value is NSNull) {
            guard let location = value as? [String: Any] else { throw TminiError.invalidResponse }
            for field in ["locationSystem", "latitude", "longitude"] {
                if let value = location[field] {
                    guard let value = value as? String, value.count <= 100 else { throw TminiError.invalidResponse }
                    if !value.isEmpty { lines.append("柜机\(field)（接口说明）：\(value)") }
                }
            }
        }
        var info = lines.joined(separator: "\n")
        var latestText = latest.text
        var safeName = name
        var safeCarrier = carrier
        // A malicious server must not echo the request key into stored query information.
        if let secret, !secret.isEmpty {
            info = info.replacingOccurrences(of: secret, with: "[已隐藏]")
            latestText = latestText.replacingOccurrences(of: secret, with: "[已隐藏]")
            safeName = safeName.replacingOccurrences(of: secret, with: "[已隐藏]")
            safeCarrier = safeCarrier.replacingOccurrences(of: secret, with: "[已隐藏]")
        }
        guard info.count <= 10000 else { throw TminiError.invalidResponse }
        return UAPITrackingResult(trackingNumber: expectedNumber, carrierName: safeName, carrierCode: safeCarrier, status: status, logisticsInfo: latestText, logisticsTime: latest.time, queryInfo: info, queriedAt: Date())
    }
}
