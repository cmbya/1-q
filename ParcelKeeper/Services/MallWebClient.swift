import Foundation
import WebKit
import UIKit

/// Buyer web pages, not merchant Open Platform APIs. No cross-platform credential sharing.
enum MallPlatform: String, CaseIterable, Identifiable, Codable {
    case jd, pdd
    var id: String { rawValue }
    var title: String { self == .jd ? "京东" : "拼多多" }
    var loginURL: URL {
        var url = URLComponents(string: self == .jd ? "https://plogin.m.jd.com/login/login" : "https://mobile.yangkeduo.com/login.html")!
        url.queryItems = self == .jd
            ? [.init(name: "appid", value: "300"), .init(name: "returnurl", value: ordersURL.absoluteString)]
            : [.init(name: "_x_no_login_launch", value: "1"), .init(name: "from", value: ordersURL.absoluteString)]
        return url.url!
    }
    var userAgent: String {
        self == .pdd
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15"
            : "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1"
    }
    var ordersURL: URL { URL(string: self == .jd ? "https://trade.m.jd.com/order/orderlist_jdm.shtml" : "https://mobile.yangkeduo.com/orders.html")! }
    var sessionService: String { "ParcelKeeper.Mall.Web.\(rawValue)" }
    func allowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        let domains = self == .jd ? ["jd.com"] : ["yangkeduo.com", "pinduoduo.com"]
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
    var sourceURL: String? = nil
    var id: String { trackingNumber }
}
protocol MallTrackingQuerying {
    func query(platform: String, orderID: String, trackingNumber: String) async throws -> UAPITrackingResult
    func query(platform: String, orderID: String, trackingNumber: String, sourceURL: String?) async throws -> UAPITrackingResult
}
extension MallTrackingQuerying {
    func query(platform: String, orderID: String, trackingNumber: String, sourceURL: String?) async throws -> UAPITrackingResult {
        try await query(platform: platform, orderID: orderID, trackingNumber: trackingNumber)
    }
}
struct MallTrackingClient: MallTrackingQuerying {
    func query(platform: String, orderID: String, trackingNumber: String) async throws -> UAPITrackingResult {
        try await query(platform: platform, orderID: orderID, trackingNumber: trackingNumber, sourceURL: nil)
    }
    func query(platform: String, orderID: String, trackingNumber: String, sourceURL: String?) async throws -> UAPITrackingResult {
        guard let platform = MallPlatform(rawValue: platform) else { throw MallWebError.unsupported }
        try Task.checkCancellation()
        let cookies = try MallSession(platform: platform).load()
        if platform == .jd {
            return try await MallWebClient(platform: platform, cookies: cookies).query(orderID: orderID, trackingNumber: trackingNumber, sourceURL: sourceURL)
        }
        return try await MallDirectClient(platform: platform, cookies: cookies).query(orderID: orderID, trackingNumber: trackingNumber)
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
        let bare = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        guard !cookie.name.isEmpty, cookie.name.utf8.count <= 256, cookie.value.utf8.count <= 16384,
              !cookie.name.contains(where: { $0.isWhitespace || $0 == ";" || $0 == "=" }),
              !cookie.value.contains(where: { $0.isNewline || $0 == ";" }),
              let url = URL(string: "https://" + bare + (cookie.path.isEmpty ? "/" : cookie.path)) else { return false }
        return applies(cookie, to: url, platform: platform)
    }
    static func hasLoginCredentials(_ cookies: [TaobaoTrialCookie], platform: MallPlatform) -> Bool {
        let relevant = cookies.filter { applies($0, to: platform.ordersURL, platform: platform) && !$0.value.isEmpty }
        let names = Set(relevant.map(\.name))
        return platform == .jd
            ? !names.isDisjoint(with: ["thor", "pt_key"]) && !names.isDisjoint(with: ["pin", "pt_pin", "_pst"])
            : names.contains("PDDAccessToken") && (names.contains("pdd_user_id") || names.contains("pdduid"))
    }
    func load() throws -> [TaobaoTrialCookie] {
        do {
            guard let text = try keys.read(), text.utf8.count < 100_000 else { throw MallWebError.authentication }
            let cookies = try JSONDecoder().decode([TaobaoTrialCookie].self, from: Data(text.utf8))
            guard !cookies.isEmpty, cookies.allSatisfy({ Self.valid($0, platform: platform) }) else { throw MallWebError.authentication }
            return cookies
        } catch { throw MallWebError.authentication }
    }
    func save(_ cookies: [TaobaoTrialCookie]) throws {
        guard !cookies.isEmpty, cookies.allSatisfy({ Self.valid($0, platform: platform) }) else { throw MallWebError.authentication }
        do {
            let data = try JSONEncoder().encode(cookies)
            guard data.count < 100_000, let text = String(data: data, encoding: .utf8) else { throw MallWebError.authentication }
            try keys.save(text)
            guard try keys.read() == text else { throw MallWebError.authentication }
        } catch { throw MallWebError.authentication }
    }
    func clear() throws {
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
        guard let latest = points.max(by: { $0.date < $1.date }) else { throw MallWebError.noTrace }
        // Only the latest dated event may contribute a conservative status.
        return UAPITrackingResult(trackingNumber: number, carrierName: carrier, carrierCode: "", status: MallDeliveryState.resolve(latest: latest.text),
            logisticsInfo: String(latest.text.prefix(1000)), logisticsTime: latest.date,
            queryInfo: (["\(platform.title)网页物流（非UAPI）"] + points.sorted { $0.date > $1.date }.map { ShipmentDateDisplay.string($0.date) + " " + $0.text }).joined(separator: "\n"), queriedAt: Date())
    }
}

enum MallWebParser {
    static func identifier(_ value: String, platform: MallPlatform) -> Bool {
        let pattern = platform == .jd ? #"^[0-9]{6,32}$"# : #"^[0-9]{6}-[0-9]{6,32}$"#
        return value.range(of: pattern, options: .regularExpression).map { $0 == (value.startIndex..<value.endIndex) } ?? false
    }
    static func waybill(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9]{6,40}$"#, options: .regularExpression).map { $0 == (value.startIndex..<value.endIndex) } ?? false
    }
    static func detailURL(platform: MallPlatform, orderID: String) throws -> URL {
        guard identifier(orderID, platform: platform) else { throw MallWebError.identityMismatch }
        var components = URLComponents(string: platform == .jd ? "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml" : "https://mobile.yangkeduo.com/order.html")!
        components.queryItems = [URLQueryItem(name: platform == .jd ? "dealId" : "order_sn", value: orderID)]
        guard let url = components.url else { throw MallWebError.unsupported }
        return url
    }
    static func orders(_ root: [String: Any], platform: MallPlatform) throws -> [MallWebOrder] {
        let array: [[String: Any]]?
        if platform == .jd { array = (root["body"] as? [String: Any])?["orderList"] as? [[String: Any]] }
        else { array = root["orders"] as? [[String: Any]] ?? (root["result"] as? [String: Any])?["orders"] as? [[String: Any]] }
        guard let array, array.count <= 200 else { throw MallWebError.unsupported }
        var result: [MallWebOrder] = []
        for object in array {
            let idKey = platform == .jd ? "orderId" : "order_sn"
            let id = object[idKey] as? String ?? (object[idKey] as? NSNumber)?.stringValue ?? ""
            let url = try detailURL(platform: platform, orderID: id)
            let status = platform == .jd ? (object["orderStatusInfo"] as? [String: Any])?["orderStatusName"] as? String ?? "" : object["order_status_prompt"] as? String ?? ""
            if ["取消", "关闭", "退款", "待付款", "未支付", "待发货", "待成团"].contains(where: status.contains) { continue }
            let goods = object[platform == .jd ? "wareInfoList" : "order_goods"] as? [[String: Any]]
            let title = goods?.first?[platform == .jd ? "wareName" : "goods_name"] as? String ?? "\(platform.title)订单"
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
    static func jdDetail(_ root: [String: Any]) throws -> MallWebDetail {
        guard let body = root["body"] as? [String: Any], let number = body["carriageId"] as? String,
              waybill(number), let traces = body["tracePointVOList"] as? [[String: Any]], traces.count <= 500 else { throw MallWebError.unsupported }
        let points = try traces.map { node -> MallWebPoint in
            guard let time = date(node["createTime"]), let text = node["wlStateDesc"] as? String, !text.isEmpty else { throw MallWebError.unsupported }
            return MallWebPoint(date: time, text: String(text.prefix(1000)))
        }
        guard !points.isEmpty else { throw MallWebError.noTrace }
        return MallWebDetail(number: number, carrier: String((body["carrier"] as? String ?? "").prefix(100)), points: points)
    }
    /// DOM layout reference: Halo0sama/ExpressAssistant JdTrackFetcher.kt,
    /// b892565502d381a58a5a2c57e6d9068e07648c7a. Require a real visible waybill;
    /// never copy its order-ID substitution or ambiguous neighboring-text pairing.
    static func jdDOM(text: String, url: URL, orderID: String) throws -> MallWebDetail {
        guard MallPlatform.jd.allowed(url), url.host == "trade.m.jd.com",
              url.path == "/order/deal_wuliu_jdm.shtml", identifier(orderID, platform: .jd),
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .filter({ $0.name == "dealId" }).map(\.value) == [Optional(orderID)] else { throw MallWebError.identityMismatch }
        guard text.utf8.count <= 2_000_000 else { throw MallWebError.unsupported }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var numbers = Set<String>()
        var headerLines = Set<Int>()
        var carrier = ""
        for (index, line) in lines.enumerated() {
            if line.contains("运单号") {
                guard line.hasPrefix("运单号") else { throw MallWebError.identityMismatch }
                var value = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix(":") || value.hasPrefix("：") { value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces) }
                headerLines.insert(index)
                if value.isEmpty, index + 1 < lines.count { value = lines[index + 1]; headerLines.insert(index + 1) }
                guard waybill(value), value != orderID else { throw MallWebError.identityMismatch }
                numbers.insert(value)
            }
            for label in ["国内承运人：", "国内承运人:", "承运人：", "承运人:"] where line.hasPrefix(label) {
                carrier = String(line.dropFirst(label.count).prefix(100))
                headerLines.insert(index)
            }
        }
        guard numbers.count == 1, let number = numbers.first else { throw MallWebError.identityMismatch }
        let expression = try NSRegularExpression(pattern: #"(?<![0-9])\d{4}-\d{2}-\d{2} \d{2}:\d{2}(?::\d{2})?(?![0-9:])"#)
        let keywords = ["快件", "包裹", "派件", "派送", "揽收", "签收", "发往", "到达", "转运", "投递", "取件", "出库", "配送", "妥投", "运输", "送达"]
        func isDescription(_ line: String) -> Bool {
            !["订单编号", "运单号", "联系电话", "¥", "评论", "已售"].contains(where: line.contains) && keywords.contains(where: line.contains)
        }
        // Preserve order and test both complete layouts; never greedily pair a
        // timestamp with one of two neighboring descriptions.
        enum Token { case time(Date), description(String), inline(MallWebPoint) }
        var tokens: [Token] = []
        for (index, line) in lines.enumerated() where !headerLines.contains(index) {
            if ["精选推荐", "猜你喜欢", "为你推荐"].contains(where: line.contains) { break }
            let matches = expression.matches(in: line, range: NSRange(line.startIndex..., in: line))
            if !matches.isEmpty {
                guard matches.count == 1, let match = matches.first, let range = Range(match.range, in: line),
                      let time = date(String(line[range])) else { throw MallWebError.noTrace }
                let before = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let after = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard before.isEmpty || after.isEmpty else { throw MallWebError.noTrace }
                let description = before.isEmpty ? after : before
                if description.isEmpty { tokens.append(.time(time)) }
                else if isDescription(description) { tokens.append(.inline(MallWebPoint(date: time, text: String(description.prefix(1000))))) }
                else { throw MallWebError.noTrace }
            } else if isDescription(line) {
                guard line.range(of: #"\d{2}[-/]\d{2}|\d{2}:\d{2}"#, options: .regularExpression) == nil else { throw MallWebError.noTrace }
                tokens.append(.description(String(line.prefix(1000))))
            }
            guard tokens.count <= 1000 else { throw MallWebError.unsupported }
        }
        func paired(descriptionFirst: Bool) -> [MallWebPoint]? {
            var points: [MallWebPoint] = []
            var index = 0
            while index < tokens.count {
                if case let .inline(point) = tokens[index] { points.append(point); index += 1; continue }
                guard index + 1 < tokens.count else { return nil }
                if descriptionFirst {
                    guard case let .description(description) = tokens[index], case let .time(time) = tokens[index + 1] else { return nil }
                    points.append(MallWebPoint(date: time, text: description))
                } else {
                    guard case let .time(time) = tokens[index], case let .description(description) = tokens[index + 1] else { return nil }
                    points.append(MallWebPoint(date: time, text: description))
                }
                index += 2
            }
            return points.isEmpty ? nil : points
        }
        let before = paired(descriptionFirst: true)
        let after = paired(descriptionFirst: false)
        let onlyInline = tokens.allSatisfy { if case .inline = $0 { return true }; return false }
        guard let points = before ?? after, onlyInline || (before == nil) != (after == nil) else { throw MallWebError.noTrace }
        return MallWebDetail(number: number, carrier: carrier, points: points)
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
    static func jdRequestOrderID(_ url: URL) -> String? {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var ids: [String] = []
        for item in query where ["orderid", "dealid"].contains(item.name.lowercased()) {
            guard let value = item.value else { return nil }; ids.append(value)
        }
        let bodies = query.filter { $0.name == "body" }
        guard bodies.count <= 1 else { return nil }
        if let text = bodies.first?.value {
            guard let data = text.data(using: .utf8), let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            for (key, value) in body where ["orderid", "dealid"].contains(key.lowercased()) {
                if let text = value as? String { ids.append(text) }
                else if let n = value as? NSNumber, String(cString: n.objCType) != "c" { ids.append(n.stringValue) }
                else { return nil }
            }
        }
        guard let id = ids.first, identifier(id, platform: .jd), ids.allSatisfy({ $0 == id }) else { return nil }
        return id
    }
    static func message(_ value: Any) throws -> (url: URL, root: [String: Any]) {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: Set(["type", "url", "body", "generation"])), Set(["type", "url", "body"]).isSubset(of: Set(object.keys)),
              object["type"] as? String == "response", let rawURL = object["url"] as? String, rawURL.utf8.count <= 8192,
              let url = URL(string: rawURL), let body = object["body"] as? String, body.utf8.count <= 2_000_000,
              let root = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { throw MallWebError.unsupported }
        return (url, root)
    }
    static func pageFailure(url: URL, text: String) -> MallWebError? {
        let path = url.path.lowercased()
        if ["captcha", "verify", "risk"].contains(where: path.contains) || ["请完成安全验证", "请完成验证", "拖动滑块", "请输入验证码", "访问过于频繁"].contains(where: text.contains) { return .verification }
        if path.contains("login") || url.host?.hasPrefix("passport.") == true { return .authentication }
        return nil
    }
}

/// A finite, foreground-only page observer. The site itself produces all signed SDK requests.
@MainActor final class MallWebClient: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let platform: MallPlatform
    private let cookies: [TaobaoTrialCookie]
    private var web: WKWebView?
    private var captures: [[String: Any]] = []
    private var failure: MallWebError?
    private var busy = false
    private var generation = UUID().uuidString
    private var detailOrderID: String?
    private var queryDeadline: Date?
    private(set) var diagnosticMessage = "尚未读取网页。"
    private var logOperation = UUID()
    private func log(_ event: DiagnosticEvent, reason: DiagnosticReason? = nil, counts: [DiagnosticMetric: Int] = [:]) {
        DiagnosticLog.shared.record(event, operation: logOperation, reason: reason, counts: counts)
    }
    private let isolatedContext: Bool
    init(platform: MallPlatform, cookies: [TaobaoTrialCookie], isolatedContext: Bool = false) {
        self.platform = platform; self.cookies = cookies; self.isolatedContext = isolatedContext
    }

    func verifySession() async throws {
        if platform != .jd {
            try await MallDirectClient(platform: platform, cookies: cookies).verifySession()
            return
        }
        try await prepare()
        defer { cleanup() }
        try load(platform.ordersURL)
        // Access verification recognizes the response envelope, not courier eligibility.
        var accessible = false
        for _ in 0..<40 {
            _ = try await tick()
            if captures.contains(where: { root in
                guard let body = root["body"] as? [String: Any], let list = body["orderList"] as? [[String: Any]] else { return false }
                return list.count <= 200
            }) { accessible = true; break }
        }
        guard accessible else { throw MallWebError.timeout }
        guard let web else { throw MallWebError.unsupported }
        let native = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        let current = native.map { TaobaoTrialCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, secure: $0.isSecure, expires: $0.expiresDate) }
        guard MallSession.hasLoginCredentials(current, platform: platform) else { throw MallWebError.authentication }
    }
    func fetchOrders() async throws -> [MallCandidate] {
        logOperation = UUID()
        log(.mallFetchStarted)
        var completed = false
        defer { if !completed { log(.mallFetchFailed, reason: .unknown) } }
        try await prepare()
        defer { cleanup() }
        try load(platform.ordersURL)
        let orders = try await observeOrders()
        let listDiagnostic = diagnosticMessage
        let prioritized = orders.filter { jdDatedOrders.contains($0.id) } + orders.filter { !jdDatedOrders.contains($0.id) }
        var unverifiedDate = 0
        let result = try await MallCandidateBatch.collect(orders: prioritized) { order in
            let detail = try await self.observeDetail(orderID: order.id, url: order.url)
            if self.platform == .jd {
                guard let web = self.web, let current = web.url else { throw MallWebError.identityMismatch }
                _ = try JDOrderSelection.logisticsURL(current.absoluteString, orderID: order.id)
                let text = try await web.evaluateJavaScript("document.body ? document.body.innerText.slice(0,100000) : ''") as? String ?? ""
                let recent = try JDOrderSelection.isRecentOrder(text: text)
                guard self.jdDatedOrders.contains(order.id) || recent else {
                    unverifiedDate += 1
                    throw MallWebError.noTrace
                }
                guard detail.number != order.id, !detail.carrier.isEmpty else { throw MallWebError.identityMismatch }
            }
            return detail
        }
        diagnosticMessage = listDiagnostic + "\n" + result.message + " 下单日期未知或范围外未导入\(unverifiedDate)单。"
        completed = true
        log(.mallFetchFinished, counts: [.candidates: result.candidates.count, .accepted: result.attempted, .rejected: result.failed])
        return result.candidates
    }
    func query(orderID: String, trackingNumber: String, sourceURL: String? = nil) async throws -> UAPITrackingResult {
        _ = try MallWebParser.detailURL(platform: platform, orderID: orderID)
        guard MallWebParser.waybill(trackingNumber) else { throw MallWebError.identityMismatch }
        try await prepare()
        defer { cleanup() }
        if platform == .jd {
            queryDeadline = Date().addingTimeInterval(18)
            if let sourceURL {
                let entry = try JDOrderSelection.logisticsURL(sourceURL, orderID: orderID)
                return try await observeDetail(orderID: orderID, url: entry).result(expected: trackingNumber, platform: platform)
            }
            try load(platform.ordersURL)
            let orders = try await collectJDOrders(recentMonth: false, targetOrderID: orderID)
            guard let order = orders.first(where: { $0.id == orderID }) else { throw MallWebError.identityMismatch }
            return try await observeDetail(orderID: orderID, url: order.url).result(expected: trackingNumber, platform: platform)
        }
        return try await observeDetail(orderID: orderID).result(expected: trackingNumber, platform: platform)
    }
    private func prepare() async throws {
        try Task.checkCancellation()
        guard !busy else { throw MallWebError.unsupported }
        // A detached or background WebView is not a supported Shortcuts execution environment.
        guard UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow) else { throw MallWebError.unsupported }
        guard !cookies.isEmpty, cookies.allSatisfy({ MallSession.valid($0, platform: platform) }) else { throw MallWebError.authentication }
        busy = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = isolatedContext ? WKWebsiteDataStore.nonPersistent() : MallBrowserContext.store(for: platform)
        configuration.userContentController.add(self, name: "mallResponse")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.observerScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: window.bounds, configuration: configuration)
        view.customUserAgent = platform.userAgent
        view.navigationDelegate = self
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        window.insertSubview(view, at: 0)
        web = view
        do {
            let existing = await configuration.websiteDataStore.httpCookieStore.allCookies()
            for cookie in cookies {
                try Task.checkCancellation()
                if existing.contains(where: { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }) { continue }
                var properties: [HTTPCookiePropertyKey: Any] = [.name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: cookie.path.isEmpty ? "/" : cookie.path]
                if cookie.secure { properties[.secure] = "TRUE" }
                if let expiry = cookie.expires { properties[.expires] = expiry }
                guard let native = HTTPCookie(properties: properties) else { throw MallWebError.authentication }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    configuration.websiteDataStore.httpCookieStore.setCookie(native) { continuation.resume() }
                }
            }
            try Task.checkCancellation()
        } catch { cleanup(); throw error }
    }
    private func cleanup() {
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "mallResponse")
        web?.configuration.userContentController.removeAllUserScripts()
        web?.removeFromSuperview()
        web = nil; captures.removeAll(); failure = nil; busy = false
        queryDeadline = nil; detailOrderID = nil
    }
    private func load(_ url: URL) throws {
        log(.mallPageLoad)
        guard platform.allowed(url), let web else { log(.mallNavigationRejected, reason: .url); throw MallWebError.unsupported }
        captures.removeAll(); failure = nil
        generation = UUID().uuidString
        let controller = web.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: "window.__mallGeneration='\(generation)';\n" + Self.observerScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
    }
    private func tick() async throws -> (URL, String) {
        try Task.checkCancellation()
        if let queryDeadline, Date() >= queryDeadline { log(.mallTimeout, reason: .timeout); throw MallWebError.timeout }
        try await Task.sleep(nanoseconds: 500_000_000)
        guard UIApplication.shared.applicationState == .active else { throw MallWebError.unsupported }
        if let failure { log(.mallFetchFailed, reason: failure == .authentication ? .authentication : failure == .verification ? .verification : .unsupported); throw failure }
        guard let web, let url = web.url, platform.allowed(url) else { log(.mallNavigationRejected, reason: .url); throw MallWebError.unsupported }
        let text: String
        do { text = try await web.evaluateJavaScript("document.body ? document.body.innerText.slice(0,100000) : ''") as? String ?? "" }
        catch { throw MallWebError.unsupported }
        try Task.checkCancellation()
        if let error = MallWebParser.pageFailure(url: url, text: text) { throw error }
        return (url, text)
    }
    private func observeOrders(recentMonth: Bool = true) async throws -> [MallWebOrder] {
        if platform == .jd { return try await collectJDOrders(recentMonth: recentMonth) }
        diagnosticMessage = "阶段：订单列表；等待接口或可识别订单页面。"
        for attempt in 0..<40 {
            _ = try await tick()
            if platform != .jd {
                if let root = captures.first { return try MallWebParser.orders(root, platform: platform) }
                continue
            }

        }
        diagnosticMessage += " 订单列表等待超时；未进入逐单物流。"
        throw MallWebError.timeout
    }
    private var jdDatedOrders = Set<String>()
    /// Bounded page-generated collection, like ExpressAssistant scrollAndCollect.
    private func collectJDOrders(recentMonth: Bool, targetOrderID: String? = nil) async throws -> [MallWebOrder] {
        jdDatedOrders.removeAll()
        var collected: [MallWebOrder] = []
        var capturedOrderIDs = Set<String>()
        var seenResponseCount = 0
        var recognized = false
        var total: Int?
        var excludedIDs = Set<String>()
        for attempt in 0..<(targetOrderID == nil ? 120 : 16) {
            _ = try await tick()
            for root in captures.dropFirst(seenResponseCount) {
                do {
                    excludedIDs.formUnion(JDOrderSelection.excludedIDs(root))
                    collected.removeAll { excludedIDs.contains($0.id) }
                    jdDatedOrders.subtract(excludedIDs)
                    let probes = try JDOrderSelection.probes(root)
                    recognized = true
                    if let body = root["body"] as? [String: Any] {
                        if let rows = body["orderList"] as? [[String: Any]] {
                            for row in rows {
                                if let id = row["orderId"] as? String { capturedOrderIDs.insert(id) }
                                else if let id = row["orderId"] as? NSNumber { capturedOrderIDs.insert(id.stringValue) }
                            }
                        }
                        if let n = body["totalNum"] as? NSNumber, n.intValue >= 0 { total = n.intValue }
                    }
                    for order in probes where !excludedIDs.contains(order.id) && !collected.contains(where: { $0.id == order.id }) {
                        if collected.count < 200 { collected.append(order) }
                    }
                } catch MallWebError.unsupported { continue }
            }
            seenResponseCount = captures.count
            if attempt % 6 == 0 || attempt % 6 == 5 {
                log(.mallCollectionProgress, counts: [.round: attempt, .responses: captures.count, .rows: capturedOrderIDs.count, .candidates: collected.count])
                do {
                  if let snapshot = try await web?.evaluateJavaScript(JDOrderSelection.domScript) {
                    let report = try JDOrderSelection.inspectDOM(snapshot, recentMonth: recentMonth)
                    recognized = true
                    for order in report.orders where !excludedIDs.contains(order.id) {
                        jdDatedOrders.insert(order.id)
                        if let index = collected.firstIndex(where: { $0.id == order.id }) { collected[index] = order }
                        else if collected.count < 200 { collected.append(order) }
                    }
                  }
                } catch MallWebError.unsupported { /* An unfinished DOM is not a failed API page. */ }
                // Trigger only normal page scrolling; never synthesize signed API requests.
                if targetOrderID == nil || !collected.contains(where: { $0.id == targetOrderID }) {
                    _ = try await web?.evaluateJavaScript("(() => { const e=document.scrollingElement; if(e) window.scrollBy(0, Math.max(300,window.innerHeight*0.8)); })()")
                }
            }
            diagnosticMessage = "阶段：订单采集；已观察\(capturedOrderIDs.count)单，待详情核实\(collected.count)单；已签收保留，未知类型不等于即时配送。"
            if let targetOrderID, collected.contains(where: { $0.id == targetOrderID }) { return collected }
            if let total, capturedOrderIDs.count >= total, attempt >= 5 { break }
            if captures.count >= 20 || collected.count >= 200 { break }
        }
        guard recognized else { log(.mallTimeout, reason: .timeout, counts: [.responses: captures.count]); throw MallWebError.timeout }
        diagnosticMessage += " 已到采集上限或平台总数；非全量保证。逐单最多核实24单、取得8票即止，日期未知不会导入。"
        log(.mallCollectionFinished, counts: [.rows: capturedOrderIDs.count, .candidates: collected.count, .responses: captures.count])
        return collected
    }
    private func observeDetail(orderID: String, url: URL? = nil) async throws -> MallWebDetail {
        log(.mallDetailStarted)
        diagnosticMessage = "阶段：逐单物流页面；尚未取得匹配运单与轨迹。"
        let target = try url ?? MallWebParser.detailURL(platform: platform, orderID: orderID)
        if platform == .jd { _ = try JDOrderSelection.logisticsURL(target.absoluteString, orderID: orderID) }
        detailOrderID = orderID
        try load(target)
        var clicked = false
        for attempt in 0..<40 {
            let (url, text) = try await tick()
            if platform == .jd {
                guard url.path == "/order/deal_wuliu_jdm.shtml" else { continue }
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard items.filter({ $0.name == "dealId" }).map(\.value) == [Optional(orderID)] else { throw MallWebError.identityMismatch }
                // Prefer the page's original trace API; empty/unknown responses may still render.
                for root in captures {
                    do { return try MallWebParser.jdDetail(root) }
                    catch MallWebError.noTrace { continue }
                    catch MallWebError.unsupported { continue }
                }
                if attempt >= 9 { // Five-second render grace, within the existing 20-second deadline.
                    do { return try MallWebParser.jdDOM(text: text, url: url, orderID: orderID) }
                    catch MallWebError.noTrace { continue }
                    catch MallWebError.identityMismatch { continue } // No matching visible identity, no result/write.
                }
            } else if url.path == "/goods_express.html" {
                do { return try MallWebParser.pddDetail(text: text, url: url, orderID: orderID) }
                catch MallWebError.noTrace { continue } // Render may not have completed; deadline remains fixed.
                catch MallWebError.identityMismatch {
                    // Header may not yet be rendered, but URL identity is never relaxed.
                    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    guard items.filter({ $0.name == "order_sn" }).map(\.value) == [Optional(orderID)] else { throw MallWebError.identityMismatch }
                    continue
                }
            } else if url.path == "/order.html", !clicked {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard items.filter({ $0.name == "order_sn" }).map(\.value) == [Optional(orderID)] else { throw MallWebError.identityMismatch }
                // Read-only logistics control only. Never broad substring-click, purchase, pay or confirm receipt.
                clicked = (try await web?.evaluateJavaScript(Self.logisticsClickScript) as? Bool) == true
            }
        }
        log(.mallTimeout, reason: .timeout)
        throw MallWebError.timeout
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, platform.allowed(url), navigationAction.targetFrame != nil else {
            if navigationAction.targetFrame?.isMainFrame != false { failure = .unsupported }
            decisionHandler(.cancel); return
        }
        if let error = MallWebParser.pageFailure(url: url, text: ""), navigationAction.targetFrame?.isMainFrame == true { failure = error }
        decisionHandler(failure == nil ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url, platform.allowed(url) else {
            if navigationResponse.isForMainFrame { failure = .unsupported }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log(.mallPageFinished)
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            do {
                let ready = try await webView.evaluateJavaScript("window.__mallObserverReady === true") as? Bool ?? false
                guard self.web === webView else { return }
                let observed = try await webView.evaluateJavaScript("window.__mallRequestsObserved || 0") as? Int ?? 0
                self.log(ready ? .mallScriptReady : .mallScriptFailed, reason: ready ? nil : .unsupported, counts: [.accepted: observed])
            } catch { self.log(.mallScriptFailed, reason: .unsupported) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log(.mallNavigationFailed, reason: .network, counts: [.errorCode: (error as NSError).code]); failure = .unsupported
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log(.mallNavigationFailed, reason: .network, counts: [.errorCode: (error as NSError).code]); failure = .unsupported
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { log(.mallProcessTerminated); failure = .unsupported }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "mallResponse", message.frameInfo.isMainFrame,
              let current = web?.url, platform.allowed(current),
              let frame = message.frameInfo.request.url, platform.allowed(frame), frame.host == current.host else { log(.mallBridgeRejected, reason: .frame); return }
        guard let envelope = message.body as? [String: Any], envelope["generation"] as? String == generation else { log(.mallBridgeRejected, reason: .generation); return }
        do {
            let packet = try MallWebParser.message(message.body)
            guard platform.allowed(packet.url) else { throw MallWebError.unsupported }
            let jd = platform == .jd && packet.url.host == "api.m.jd.com"
            let functionID = URLComponents(url: packet.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "functionId" })?.value
            let listPage = current.path == platform.ordersURL.path
            let accepted = jd ? functionID == (listPage ? "order_list_m" : "get_logistics_list_by_order_m") :
                (platform == .pdd && listPage && packet.url.path.hasSuffix("/aristotle/order_list_v4"))
            guard accepted else { log(.mallResponseRejected, reason: .interface); return }
            if jd && !listPage {
                // A live page URL is not evidence of response ownership.
                guard let expected = detailOrderID, MallWebParser.jdRequestOrderID(packet.url) == expected else { log(.mallResponseRejected, reason: .ownership); return }
                if let id = (packet.root["body"] as? [String: Any])?["orderId"] {
                    guard String(describing: id) == expected else { throw MallWebError.identityMismatch }
                }
            }
            let limit = platform == .jd && listPage ? 20 : 4
            guard captures.count < limit else { log(.mallResponseRejected, reason: .limit); return }
            captures.append(packet.root)
            let body = packet.root["body"] as? [String: Any]
            let rows = body?["orderList"] as? [[String: Any]] ?? []
            log(.mallResponseAccepted, counts: [.responses: captures.count, .rows: rows.count,
                .hasProgress: rows.filter { $0["progressInfo"] is [String: Any] }.count,
                .hasType: rows.filter { ($0["progressInfo"] as? [String: Any])?["progressId"] is String }.count,
                .hasLink: rows.filter { ($0["progressInfo"] as? [String: Any])?["progressLink"] is String }.count])
        } catch { log(.mallResponseRejected, reason: .envelope); failure = .unsupported }
    }
    private static let logisticsClickScript = #"""
    (() => {
      if (location.pathname !== '/order.html') return false;
      const allowed = new Set(['查看物流','查物流','物流详情','物流信息']);
      const controls = Array.from(document.querySelectorAll('a,button,span,div'));
      const target = controls.find(e => allowed.has((e.innerText || '').trim()) &&
        e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().height > 0 &&
        !Array.from(e.children).some(c => allowed.has((c.innerText || '').trim())));
      if (!target) return false;
      target.click(); return true;
    })()
    """#
    private static let observerScript = JDWebScripts.observer
}
