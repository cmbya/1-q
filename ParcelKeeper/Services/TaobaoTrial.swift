import Foundation
import CryptoKit

// Experimental client endpoints; these are NOT Open Platform OAuth APIs.
enum TaobaoTrialError: LocalizedError {
    case login, verification, shape, network, credentials, emptyWaybill
    var errorDescription: String? {
        switch self {
        case .login: return "淘宝登录或令牌已失效，请打开登录页重新确认。"
        case .verification: return "淘宝要求验证码或风控验证，请在淘宝页面手动处理，未自动重试。"
        case .shape: return "淘宝返回结构不受支持，未把空结果当作同步成功。"
        case .network: return "淘宝网络请求失败，未自动重试。"
        case .credentials: return "淘宝会话无法安全保存或读取，未使用明文回退。"
        case .emptyWaybill: return "该订单没有返回可用运单号，未导入。"
        }
    }
}
enum TaobaoTrialPolicy {
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "taobao.com" || host.hasSuffix(".taobao.com")
    }
}
struct TaobaoTrialCookie: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let expires: Date?
    func applies(to url: URL, now: Date = Date()) -> Bool {
        guard TaobaoTrialPolicy.allowed(url), let host = url.host?.lowercased(),
              expires.map({ $0 > now }) ?? true else { return false }
        let domain = self.domain.lowercased()
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        let domainMatch = host == bare || (domain.hasPrefix(".") && host.hasSuffix("." + bare))
        let cookiePath = path.isEmpty ? "/" : path
        let requestPath = url.path.isEmpty ? "/" : url.path
        let pathMatch = requestPath == cookiePath || (requestPath.hasPrefix(cookiePath) &&
            (cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).hasPrefix("/")))
        return domainMatch && pathMatch && (!secure || url.scheme == "https")
    }
}
struct TaobaoTrialSession {
    var keys: any AIKeyStore = AIKeychainStore(service: "ParcelKeeper.Taobao.Trial")
    func load() throws -> [TaobaoTrialCookie] {
        do {
            guard let text = try keys.read(), let data = text.data(using: .utf8), data.count < 100_000 else { throw TaobaoTrialError.login }
            return try JSONDecoder().decode([TaobaoTrialCookie].self, from: data)
        } catch let error as TaobaoTrialError { throw error }
        catch { throw TaobaoTrialError.credentials }
    }
    func save(_ cookies: [TaobaoTrialCookie]) throws {
        guard !cookies.isEmpty else { throw TaobaoTrialError.login }
        do {
            let data = try JSONEncoder().encode(cookies)
            guard data.count < 100_000, let text = String(data: data, encoding: .utf8) else { throw TaobaoTrialError.credentials }
            try keys.save(text)
            guard try keys.read() == text else { throw TaobaoTrialError.credentials }
        } catch { throw TaobaoTrialError.credentials }
    }
    func clear() throws {
        do { try keys.delete(); guard try keys.read() == nil else { throw TaobaoTrialError.credentials } }
        catch { throw TaobaoTrialError.credentials }
    }
}
struct TaobaoTrialOrder { let id: String; let title: String }
struct TaobaoTrialWaybill: Identifiable {
    var id: String { number }
    let number: String
    let carrier: String
}
struct TaobaoTrialCandidate: Identifiable {
    var id: String { number }
    let number: String
    let carrier: String
    let title: String
}
struct TaobaoTrialReport {
    var candidates: [TaobaoTrialCandidate] = []
    var scanned = 0
    var failed = 0
    var limited = false
}
enum TaobaoTrialParser {
    static func check(_ root: [String: Any]) throws {
        guard let ret = root["ret"] as? [String], !ret.isEmpty else { throw TaobaoTrialError.shape }
        if ret.contains(where: { $0.contains("USER_VALIDATE") || $0.contains("RGV") || $0.contains("VALIDATE") }) { throw TaobaoTrialError.verification }
        if ret.contains(where: { $0.contains("SESSION") || $0.contains("TOKEN") || $0.contains("LOGIN") }) { throw TaobaoTrialError.login }
        guard ret.allSatisfy({ $0 == "SUCCESS" || $0.hasPrefix("SUCCESS::") }) else { throw TaobaoTrialError.shape }
    }
    static func orders(_ root: [String: Any]) throws -> [TaobaoTrialOrder] {
        try check(root)
        guard let envelope = root["data"] as? [String: Any] else { throw TaobaoTrialError.shape }
        var inner = envelope["data"] as? [String: Any]
        if let raw = envelope["result"] as? String, let bytes = raw.data(using: .utf8) {
            inner = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }
        guard let mains = inner?["mainOrders"] as? [[String: Any]] else { throw TaobaoTrialError.shape }
        return try mains.compactMap { order in
            let extra = order["extra"] as? [String: Any]
            let status = order["statusInfo"] as? [String: Any]
            guard extra?["tradeStatus"] as? String == "WAIT_BUYER_CONFIRM_GOODS" ||
                  ["等待买家确认收货", "待收货"].contains(status?["text"] as? String ?? "") else { return nil }
            guard let id = order["id"] as? String,
                  id.range(of: #"^[0-9]{6,32}$"#, options: .regularExpression) != nil else { throw TaobaoTrialError.shape }
            let subs = order["subOrders"] as? [[String: Any]] ?? []
            let title = (subs.first?["itemInfo"] as? [String: Any])?["title"] as? String ?? "淘宝订单"
            return TaobaoTrialOrder(id: id, title: String(title.prefix(200)))
        }
    }
    static func waybills(_ root: [String: Any]) throws -> [TaobaoTrialWaybill] {
        try check(root)
        guard let data = root["data"] as? [String: Any] else { throw TaobaoTrialError.shape }
        var result: [String: TaobaoTrialWaybill] = [:]
        var visited = 0
        func walk(_ value: Any, depth: Int) throws {
            visited += 1
            guard depth <= 16, visited <= 10000 else { throw TaobaoTrialError.shape }
            if let array = value as? [Any] { for item in array { try walk(item, depth: depth + 1) }; return }
            guard let object = value as? [String: Any] else { return }
            for key in ["mailNo", "waybillCode", "logisticsNo"] {
                if let raw = object[key] {
                    guard let text = raw as? String, let number = try? ShipmentShortcutParser.number(text),
                          number == text.uppercased() else { throw TaobaoTrialError.shape }
                    let carrier = object["companyName"] as? String ?? object["cpName"] as? String ?? object["name"] as? String ?? ""
                    let previous = result[number]
                    if let previous, !previous.carrier.isEmpty, !carrier.isEmpty, previous.carrier != carrier { throw TaobaoTrialError.shape }
                    result[number] = TaobaoTrialWaybill(number: number, carrier: String(carrier.prefix(100)))
                }
            }
            for item in object.values { try walk(item, depth: depth + 1) }
        }
        try walk(data, depth: 0)
        guard !result.isEmpty else { throw TaobaoTrialError.emptyWaybill }
        return result.values.sorted { $0.number < $1.number }
    }
}

/// Redirect refusing, ephemeral networking. No cookies are put into URLs or logs.
final class TaobaoTrialClient {
    private let network: any AINetworking
    private var cookies: [TaobaoTrialCookie]
    init(cookies: [TaobaoTrialCookie], network: any AINetworking = AISecureNetwork()) {
        self.cookies = cookies; self.network = network
    }
    private func call(_ api: String, payload: [String: Any]) async throws -> [String: Any] {
        let endpoint = URL(string: "https://h5api.m.taobao.com/h5/\(api)/1.0/")!
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let body = String(data: data, encoding: .utf8) else { throw TaobaoTrialError.shape }
        for attempt in 0...1 {
            try Task.checkCancellation()
            let applicable = cookies.filter { $0.applies(to: endpoint) }
            let token = applicable.first(where: { $0.name == "_m_h5_tk" })?.value.components(separatedBy: "_").first ?? ""
            let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
            let source = "\(token)&\(timestamp)&12574478&\(body)"
            let sign = Insecure.MD5.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
            var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            url.queryItems = ["appKey": "12574478", "t": timestamp, "sign": sign, "api": api, "v": "1.0",
                              "type": "originaljson", "dataType": "originaljson", "data": body].map { URLQueryItem(name: $0.key, value: $0.value) }
            var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue(applicable.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
            request.setValue("https://main.m.taobao.com/", forHTTPHeaderField: "Referer")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let bytes: Data; let response: URLResponse
            do { (bytes, response) = try await network.data(for: request) }
            catch is CancellationError { throw CancellationError() }
            catch { throw TaobaoTrialError.network }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  bytes.count <= 2_000_000 else { throw TaobaoTrialError.network }
            let newCookies = HTTPCookie.cookies(withResponseHeaderFields: http.allHeaderFields.reduce(into: [String: String]()) { result, item in
                if let key = item.key as? String, let value = item.value as? String { result[key] = value }
            }, for: endpoint)
            for cookie in newCookies where cookie.name == "_m_h5_tk" || cookie.name == "_m_h5_tk_enc" {
                let value = TaobaoTrialCookie(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, secure: cookie.isSecure, expires: cookie.expiresDate)
                guard value.applies(to: endpoint) else { continue }
                cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
                cookies.append(value)
            }
            guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw TaobaoTrialError.shape }
            let ret = root["ret"] as? [String] ?? []
            if attempt == 0 && ret.contains(where: { $0.hasPrefix("FAIL_SYS_TOKEN_EXOIRED") || $0.hasPrefix("FAIL_SYS_TOKEN_EXPIRED") || $0.hasPrefix("FAIL_SYS_TOKEN_EMPTY") }) && !newCookies.isEmpty { continue }
            try TaobaoTrialParser.check(root)
            return root
        }
        throw TaobaoTrialError.login
    }
    func fetch() async throws -> TaobaoTrialReport {
        let root = try await call("mtop.taobao.order.queryboughtlistv2", payload: [
            "tabCode": "all", "page": 1, "OrderType": "OrderList", "templateConfigVersion": "0", "appName": "tborder", "appVersion": "3.0",
            "condition": "{\"version\":\"1.0.0\",\"appChannel\":\"\"}", "ttid": "201200@taobao_h5_9.18.0", "requestIdentity": "#t#ip#h5"
        ])
        let orders = try TaobaoTrialParser.orders(root)
        var report = TaobaoTrialReport(limited: true) // First page only, never claim completeness.
        for order in orders.prefix(8) {
            try Task.checkCancellation()
            report.scanned += 1
            do {
                let response = try await call("mtop.taobao.logistics.detailorlist.query", payload: ["orderId": order.id])
                for item in try TaobaoTrialParser.waybills(response) {
                    if !report.candidates.contains(where: { $0.number == item.number }) {
                        report.candidates.append(.init(number: item.number, carrier: item.carrier, title: order.title))
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch TaobaoTrialError.emptyWaybill { report.failed += 1 }
            // Stop on auth, verification, network or unrecognised schema. No hidden partial success.
        }
        return report
    }
}
