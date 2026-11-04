import Foundation
import WebKit

/// Supported direct mall connector. Session presence alone does not prove authentication.
enum MallPlatform: String, CaseIterable, Identifiable, Codable {
    case pdd
    var id: String { rawValue }
    var title: String { "拼多多" }
    var loginURL: URL {
        var url = URLComponents(string: "https://mobile.yangkeduo.com/login.html")!
        url.queryItems = [.init(name: "_x_no_login_launch", value: "1"), .init(name: "from", value: ordersURL.absoluteString)]
        return url.url!
    }
    var userAgent: String {
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15"
    }
    var ordersURL: URL { URL(string: "https://mobile.yangkeduo.com/orders.html")! }
    var sessionService: String { "ParcelKeeper.Mall.Web.\(rawValue)" }
    func allowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        let domains = ["yangkeduo.com", "pinduoduo.com"]
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
/// Preserve platform web storage in memory across login/orders/logistics, without plaintext persistence.
@MainActor enum MallBrowserContext {
    private static var stores: [MallPlatform: WKWebsiteDataStore] = [:]
    static func store(for platform: MallPlatform) -> WKWebsiteDataStore {
        if let current = stores[platform] { return current }
        let next = WKWebsiteDataStore.nonPersistent()
        stores[platform] = next
        return next
    }

    static func detach(_ platform: MallPlatform) -> WKWebsiteDataStore {
        stores.removeValue(forKey: platform) ?? WKWebsiteDataStore.nonPersistent()
    }
    static func removeData(from store: WKWebsiteDataStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { continuation.resume() }
        }
    }
    static func clear(_ platform: MallPlatform) async {
        let old = detach(platform)
        await removeData(from: old)
    }
}
struct MallCandidate: Identifiable {
    let trackingNumber: String
    let carrier: String
    let title: String
    let orderID: String
    var id: String { trackingNumber }

}
protocol MallTrackingQuerying {
    func query(platform: String, orderID: String, trackingNumber: String) async throws -> UAPITrackingResult
}
struct MallTrackingClient: MallTrackingQuerying {
    func query(platform: String, orderID: String, trackingNumber: String) async throws -> UAPITrackingResult {
        guard let platform = MallPlatform(rawValue: platform) else { throw MallWebError.unsupported }
        try Task.checkCancellation()
        let generation = MallSession.generation(for: platform)
        let cookies = try MallSession.withGeneration(platform: platform, expected: generation) {
            try MallSession(platform: platform).load()
        }
        let result = try await MallDirectClient(platform: platform, cookies: cookies).query(orderID: orderID, trackingNumber: trackingNumber)
        try Task.checkCancellation()
        return try MallSession.withGeneration(platform: platform, expected: generation) { result }
    }
}
enum MallWebError: LocalizedError, Equatable {
    case authentication, verification, unsupported, identityMismatch, noTrace, timeout
    var stopsBatch: Bool { self == .authentication || self == .verification }
    var errorDescription: String? {
        switch self {
        case .authentication: return "商城登录失效或安全会话不可用，请在App内重新登录。"
        case .verification: return "商城要求安全验证，请打开App内商城页面手动处理；未绕过验证。"
        case .unsupported: return "商城网页结构或运行环境不受支持，请打开App前台重试；未把空结果当作成功。"
        case .identityMismatch: return "商城返回的订单或运单身份不匹配，未更新物流。"
        case .noTrace: return "商城未返回带真实运单号的有效物流轨迹，未更新。"
        case .timeout: return "商城网页加载超时，请打开App前台重试；未自动重试。"
        }
    }
}
struct MallSession {
    // Synchronous only: never retain this lock across await. Recursive so guarded
    // business commits can load/save without a check-then-write race.
    private static let sessionLock = NSRecursiveLock()
    private static var generations: [MallPlatform: UUID] = [:]
    private static func currentGeneration(for platform: MallPlatform) -> UUID {
        if let value = generations[platform] { return value }
        let value = UUID(); generations[platform] = value; return value
    }
    private static func advanceGeneration(for platform: MallPlatform) { generations[platform] = UUID() }
    static func generation(for platform: MallPlatform) -> UUID {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return currentGeneration(for: platform)
    }
    static func withGeneration<T>(platform: MallPlatform, expected: UUID, operation: () throws -> T) throws -> T {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard currentGeneration(for: platform) == expected else { throw CancellationError() }
        return try operation()
    }
    let platform: MallPlatform
    var keys: any AIKeyStore
    init(platform: MallPlatform, keys: (any AIKeyStore)? = nil) {
        self.platform = platform
        self.keys = keys ?? AIKeychainStore(service: platform.sessionService)
    }
    static func applies(_ cookie: TaobaoTrialCookie, to url: URL, platform: MallPlatform, now: Date = Date()) -> Bool {
        guard platform.allowed(url), let host = url.host?.lowercased(),
              cookie.expires.map({ $0 > now }) ?? true else { return false }
        let domain = cookie.domain.lowercased()
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard !bare.isEmpty, platform.allowed(URL(string: "https://" + bare) ?? URL(fileURLWithPath: "/")),
              host == bare || (domain.hasPrefix(".") && host.hasSuffix("." + bare)) else { return false }
        let path = cookie.path.isEmpty ? "/" : cookie.path
        let request = url.path.isEmpty ? "/" : url.path
        return path.hasPrefix("/") && (request == path || (request.hasPrefix(path) &&
            (path.hasSuffix("/") || request.dropFirst(path.count).hasPrefix("/")))) && (!cookie.secure || url.scheme == "https")
    }
    static func valid(_ cookie: TaobaoTrialCookie, platform: MallPlatform) -> Bool {
        structurallyValid(cookie, platform: platform) && (cookie.expires.map { $0 > Date() } ?? true)
    }
    // Validate all entries before dropping expired cookies, including untrusted
    // expired entries. Expiration itself is not structural corruption.
    static func structurallyValid(_ cookie: TaobaoTrialCookie, platform: MallPlatform) -> Bool {
        let bare = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        guard !cookie.name.isEmpty, cookie.name.utf8.count <= 256, cookie.value.utf8.count <= 16384,
              !bare.isEmpty, bare.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*$"#, options: .regularExpression) != nil,
              ![cookie.name, cookie.value, cookie.path].contains(where: { value in
                  value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
              }),
              cookie.path.isEmpty || cookie.path.hasPrefix("/"),
              !cookie.path.contains(where: { $0.isWhitespace || $0.isNewline }),
              !cookie.name.contains(where: { $0.isWhitespace || $0 == ";" || $0 == "=" }),
              !cookie.value.contains(where: { $0.isNewline || $0 == ";" }),
              let url = URL(string: "https://" + bare), platform.allowed(url) else { return false }
        return true
    }

    static func hasLoginCredentials(_ cookies: [TaobaoTrialCookie], platform: MallPlatform) -> Bool {
        let relevant = cookies.filter { applies($0, to: platform.ordersURL, platform: platform) && !$0.value.isEmpty }
        let names = Set(relevant.map(\.name))
        // Presence is only a preflight; each connector verifies its own actual order response.
        return names.contains("PDDAccessToken") && (names.contains("pdd_user_id") || names.contains("pdduid"))
    }
    func load() throws -> [TaobaoTrialCookie] {
        Self.sessionLock.lock(); defer { Self.sessionLock.unlock() }
        do {
            guard let text = try keys.read(), text.utf8.count < 100_000 else { throw MallWebError.authentication }
            let cookies = try JSONDecoder().decode([TaobaoTrialCookie].self, from: Data(text.utf8))
            guard !cookies.isEmpty, cookies.allSatisfy({ Self.structurallyValid($0, platform: platform) }) else { throw MallWebError.authentication }
            let now = Date()
            let active = cookies.filter { $0.expires.map { $0 > now } ?? true }
            guard Self.hasLoginCredentials(active, platform: platform) else { throw MallWebError.authentication }
            return active
        } catch { throw MallWebError.authentication }
    }
    private static func encoded(_ cookies: [TaobaoTrialCookie]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(cookies.sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) })
    }
    private func prepared(_ cookies: [TaobaoTrialCookie]) throws -> String {
        guard !cookies.isEmpty, cookies.allSatisfy({ Self.valid($0, platform: platform) }),
              Self.hasLoginCredentials(cookies, platform: platform) else { throw MallWebError.authentication }
        // Preserve the existing bare Cookie-array Keychain JSON schema.
        let data = try Self.encoded(cookies)
        guard data.count < 100_000, let text = String(data: data, encoding: .utf8) else { throw MallWebError.authentication }
        return text
    }
    private func write(_ text: String) throws {
        try keys.save(text)
        guard try keys.read() == text else { throw MallWebError.authentication }
    }
    func save(_ cookies: [TaobaoTrialCookie], expectedGeneration: UUID? = nil) throws {
        let text = try prepared(cookies)
        Self.sessionLock.lock(); defer { Self.sessionLock.unlock() }
        if let expectedGeneration {
            guard Self.currentGeneration(for: platform) == expectedGeneration else { throw CancellationError() }
        }
        // A write may have changed Keychain even when it throws or readback fails.
        defer { Self.advanceGeneration(for: platform) }
        do { try write(text) } catch { throw MallWebError.authentication }
    }
    func clear() throws {
        Self.sessionLock.lock(); defer { Self.sessionLock.unlock() }
        defer { Self.advanceGeneration(for: platform) }
        do { try keys.delete(); guard try keys.read() == nil else { throw MallWebError.authentication } }
        catch { throw MallWebError.authentication }
    }
}

struct MallWebOrder { let id: String; let title: String; let url: URL }
struct MallWebPoint { let date: Date; let text: String }
struct MallWebDetail {
    let number: String
    let carrier: String
    let points: [MallWebPoint]
    func result(expected: String, platform: MallPlatform) throws -> UAPITrackingResult {
        guard number == expected else { throw MallWebError.identityMismatch }
        let events = points
        guard let latest = events.max(by: { $0.date < $1.date }) else { throw MallWebError.noTrace }
        // Only the latest dated event may contribute a conservative status.
        return UAPITrackingResult(trackingNumber: number, carrierName: carrier, carrierCode: "", status: MallDeliveryState.resolve(latest: latest.text),
            logisticsInfo: String(latest.text.prefix(1000)), logisticsTime: latest.date,
            queryInfo: (["\(platform.title)网页物流（非UAPI）"] + events.sorted { $0.date > $1.date }.map { ShipmentDateDisplay.string($0.date) + " " + $0.text }).joined(separator: "\n"), queriedAt: Date())
    }
}

enum MallWebParser {
    static func identifier(_ value: String, platform: MallPlatform) -> Bool {
        let pattern = #"^[0-9]{6}-[0-9]{6,32}$"#
        return value.range(of: pattern, options: .regularExpression).map { $0 == (value.startIndex..<value.endIndex) } ?? false
    }
    static func waybill(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9]{6,40}$"#, options: .regularExpression).map { $0 == (value.startIndex..<value.endIndex) } ?? false
    }
    static func detailURL(platform: MallPlatform, orderID: String) throws -> URL {
        guard identifier(orderID, platform: platform) else { throw MallWebError.identityMismatch }
        var components = URLComponents(string: "https://mobile.yangkeduo.com/order.html")!
        components.queryItems = [URLQueryItem(name: "order_sn", value: orderID)]
        guard let url = components.url else { throw MallWebError.unsupported }
        return url
    }
    static func orders(_ root: [String: Any], platform: MallPlatform) throws -> [MallWebOrder] {
        let array = root["orders"] as? [[String: Any]] ?? (root["result"] as? [String: Any])?["orders"] as? [[String: Any]]
        guard let array, array.count <= 200 else { throw MallWebError.unsupported }
        var result: [MallWebOrder] = []
        for object in array {
            let idKey = "order_sn"
            let id = object[idKey] as? String ?? (object[idKey] as? NSNumber)?.stringValue ?? ""
            let url = try detailURL(platform: platform, orderID: id)
            let status = object["order_status_prompt"] as? String ?? ""
            if ["取消", "关闭", "退款", "待付款", "未支付", "待发货", "待成团"].contains(where: status.contains) { continue }
            let goods = object["order_goods"] as? [[String: Any]]
            let title = goods?.first?["goods_name"] as? String ?? "\(platform.title)订单"
            if !result.contains(where: { $0.id == id }) { result.append(MallWebOrder(id: id, title: String(title.prefix(200)), url: url)) }
        }
        return result
    }
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue > 100_000_000_000 ? number.doubleValue / 1000 : number.doubleValue
            return seconds > 0 && seconds < 32_503_680_000 ? Date(timeIntervalSince1970: seconds) : nil
        }
        guard let text = value as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.isLenient = false
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text), formatter.string(from: date) == text { return date }
        }
        return nil
    }
    static func pddDetail(text: String, url: URL, orderID: String) throws -> MallWebDetail {
        guard MallPlatform.pdd.allowed(url), url.path == "/goods_express.html",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { throw MallWebError.unsupported }
        let orders = items.filter { $0.name == "order_sn" }
        let numbers = items.filter { $0.name == "tracking_number" }
        guard orders.count == 1, orders.first?.value == orderID, numbers.count == 1,
              let number = numbers.first?.value, waybill(number) else { throw MallWebError.identityMismatch }
        guard text.utf8.count <= 2_000_000 else { throw MallWebError.unsupported }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        // Require the visible carrier/number header as well as the logistics URL. Never bind a whole page's other parcels.
        guard let header = lines.first(where: { $0.contains(number) && ($0.contains(":") || $0.contains("：")) }) else { throw MallWebError.identityMismatch }
        let carrier = String(header.components(separatedBy: CharacterSet(charactersIn: ":：")).first?.prefix(100) ?? "")
        let expression = try NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}(?::\d{2})?"#)
        var points: [MallWebPoint] = []
        var time: Date?
        var description: [String] = []
        func flush() { if let time, !description.isEmpty { points.append(MallWebPoint(date: time, text: String(description.joined(separator: " ").prefix(1000)))) } }
        for line in lines {
            if ["精选推荐", "即将恢复", "本店已拼", "券后", "全店总售"].contains(where: line.contains) { break }
            if let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let range = Range(match.range, in: line) {
                flush(); time = date(String(line[range])); description = []
                let prefix = String(line[..<range.lowerBound])
                if !prefix.isEmpty { description.append(prefix) }
            } else if time != nil, ["快件", "包裹", "签收", "揽收", "发往", "到达", "派送", "配送", "送达", "投递", "取件", "运输", "转运"].contains(where: line.contains) {
                description.append(line)
            }
        }
        flush()
        guard !points.isEmpty else { throw MallWebError.noTrace }
        return MallWebDetail(number: number, carrier: carrier, points: points)
    }
    static func pageFailure(url: URL, text: String) -> MallWebError? {
        let path = url.path.lowercased()
        if ["captcha", "verify", "risk"].contains(where: path.contains) || ["请完成安全验证", "请完成验证", "拖动滑块", "请输入验证码", "访问过于频繁"].contains(where: text.contains) { return .verification }
        if path.contains("login") || url.host?.hasPrefix("passport.") == true { return .authentication }
        return nil
    }
}
