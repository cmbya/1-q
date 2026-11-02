import Foundation

protocol TaobaoTrackingQuerying {
    func query(orderID: String, trackingNumber: String) async throws -> UAPITrackingResult
}

enum TaobaoTrackingError: LocalizedError, Equatable {
    case missingBinding, unsupported, identityMismatch, noTrace, authentication, verification

    var stopsBatch: Bool {
        self == .authentication || self == .verification
    }
    var errorDescription: String? {
        switch self {
        case .missingBinding: return "该快递尚未绑定有效淘宝订单号，请重新预览并确认绑定。"
        case .unsupported: return "淘宝物流响应暂不受支持或请求失败，已保留原物流；未自动切换 UAPI。"
        case .identityMismatch: return "淘宝返回的运单号缺失、脱敏或与这票快递不一致，未更新。"
        case .noTrace: return "淘宝暂未返回可用物流轨迹，已保留原物流。"
        case .authentication: return "淘宝登录会话已失效，请重新登录；已停止后续淘宝刷新。"
        case .verification: return "淘宝要求验证，请在淘宝页面手动处理；已停止后续淘宝刷新。"
        }
    }
}

/// A single uncharged SSR request. Does not execute scripts, retry, follow redirects,
/// persist page contents or expose transport errors (which can contain a sensitive URL).
struct TaobaoTrackingClient: TaobaoTrackingQuerying {
    private let network: any AINetworking
    private let session: TaobaoTrialSession

    init(network: any AINetworking = AISecureNetwork(), session: TaobaoTrialSession = TaobaoTrialSession()) {
        self.network = network
        self.session = session
    }

    func query(orderID: String, trackingNumber: String) async throws -> UAPITrackingResult {
        try Task.checkCancellation()
        guard (6...32).contains(orderID.utf8.count),
              orderID.utf8.allSatisfy({ (48...57).contains($0) }) else { throw TaobaoTrackingError.missingBinding }
        guard TaobaoTrackingParser.validNumber(trackingNumber) else { throw TaobaoTrackingError.identityMismatch }
        var components = URLComponents(string: "https://pages-g.m.taobao.com/wow/z/app/mtb/logisticsV2/h5-detail")!
        components.queryItems = [URLQueryItem(name: "x-ssr", value: "true"), URLQueryItem(name: "bizOrderId", value: orderID)]
        guard let endpoint = components.url else { throw TaobaoTrackingError.missingBinding }
        let cookies: [TaobaoTrialCookie]
        do { cookies = try session.load().filter { $0.applies(to: endpoint) } }
        catch { throw TaobaoTrackingError.authentication }
        guard !cookies.isEmpty else { throw TaobaoTrackingError.authentication }
        // Reject damaged cookie storage rather than inserting controls into headers.
        guard cookies.allSatisfy({ cookie in
            !cookie.name.isEmpty && cookie.name.utf8.allSatisfy { (33...126).contains($0) && ![59, 61, 44].contains($0) } &&
            cookie.value.utf8.allSatisfy { (33...126).contains($0) && ![34, 59, 44, 92].contains($0) }
        }) else { throw TaobaoTrackingError.authentication }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        let bytes: Data
        let response: URLResponse
        do { (bytes, response) = try await network.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw TaobaoTrackingError.unsupported }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw TaobaoTrackingError.unsupported }
        // AISecureNetwork refuses redirects; do not inspect or follow a Location header.
        switch http.statusCode {
        case 200: break
        case 401: throw TaobaoTrackingError.authentication
        case 403: throw TaobaoTrackingError.verification
        default: throw TaobaoTrackingError.unsupported
        }
        return try TaobaoTrackingParser.parse(bytes, trackingNumber: trackingNumber, now: Date())
    }
}

/// Strictly bounded extraction of the known SSR data envelope, never a general HTML scraper.
/// Pure parsing entry point is internal so synthetic fixtures need no real account or network.
enum TaobaoTrackingParser {
    private static let maximumBytes = 2_000_000
    private static let maximumDepth = 32

    static func validNumber(_ value: String) -> Bool {
        (8...40).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
    }

    static func parse(_ bytes: Data, trackingNumber: String, now: Date) throws -> UAPITrackingResult {
        guard validNumber(trackingNumber) else { throw TaobaoTrackingError.identityMismatch }
        let root = try object(from: bytes)
        try checkCodes(root)
        guard let result = root["result"] as? [String: Any] else { throw TaobaoTrackingError.unsupported }
        try checkCodes(result)
        guard let data = result["data"] as? [String: Any] else { throw TaobaoTrackingError.unsupported }
        try checkCodes(data)
        // Both known envelopes appearing at once is ambiguous; no first-match guessing.
        let envelopes = ["newLogistics", "logisticsDetailH5"].compactMap { data[$0] }
        guard envelopes.count == 1, let envelope = envelopes[0] as? [String: Any],
              let fields = envelope["fields"] as? [String: Any] else { throw TaobaoTrackingError.unsupported }
        // A package collection alongside a selected-looking fields object is not a supported binding.
        guard !["packages", "packageList", "logisticsList", "mailList"].contains(where: { fields[$0] != nil || data[$0] != nil }) else {
            throw TaobaoTrackingError.unsupported
        }
        let company = fields["logisticCompany"] as? [String: Any]
        let identities = [fields["mailNo"], company?["mailNo"]].compactMap { $0 }
        guard !identities.isEmpty, identities.allSatisfy({ raw in
            guard let value = raw as? String else { return false }
            return validNumber(value) && value == trackingNumber
        }) else { throw TaobaoTrackingError.identityMismatch }
        // Known fields only. Unknown package/list schemas are never walked to pick a convenient match.
        guard let rawStages = fields["multiStage"] as? [Any], rawStages.count <= 500 else { throw TaobaoTrackingError.unsupported }
        var stages: [Stage] = []
        for (index, raw) in rawStages.enumerated() {
            guard let node = raw as? [String: Any] else { throw TaobaoTrackingError.unsupported }
            let rawTime = (["subtitle", "time", "timeDesc", "timeStr"].compactMap { node[$0] as? String }.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Includes the recipient/address card, not an actual event. Do not retain its PII.
            guard !rawTime.isEmpty else { continue }
            let time = try timestamp(rawTime, now: now)
            let title = (node["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = try description(node)
            let text = [title, detail].filter { !$0.isEmpty }.joined(separator: " ")
            guard !text.isEmpty, text.count <= 2000, title.count <= 100 else { throw TaobaoTrackingError.unsupported }
            stages.append(Stage(index: index, date: time.date, rawTime: rawTime, inferredYear: time.inferredYear, title: title, text: text))
        }
        guard !stages.isEmpty else { throw TaobaoTrackingError.noTrace }
        stages.sort { $0.date == $1.date ? $0.index < $1.index : $0.date > $1.date }
        let latest = stages[0]
        let carrier = company?["name"] as? String ?? company?["companyName"] as? String ?? fields["companyName"] as? String ?? ""
        guard carrier.count <= 100 else { throw TaobaoTrackingError.unsupported }
        let formatter = dateFormatter("yyyy-MM-dd HH:mm:ss")
        let history = stages.map { stage in
            let qualification = stage.inferredYear ? "；年份推断，Asia/Shanghai" : "；Asia/Shanghai"
            return "\(formatter.string(from: stage.date)) [原始：\(stage.rawTime)\(qualification)] \(stage.text)"
        }.joined(separator: "\n")
        let info = "查询来源：淘宝\n快递单号：\(trackingNumber)\n快递公司：\(carrier)\n物流轨迹：\n\(history)"
        guard info.count <= 10000 else { throw TaobaoTrackingError.unsupported }
        return UAPITrackingResult(trackingNumber: trackingNumber, carrierName: carrier, carrierCode: "", status: status(latest.title),
                                  logisticsInfo: latest.text, logisticsTime: latest.date, queryInfo: info, queriedAt: now)
    }

    private struct Stage {
        let index: Int
        let date: Date
        let rawTime: String
        let inferredYear: Bool
        let title: String
        let text: String
    }

    private static func description(_ node: [String: Any]) throws -> String {
        let label = node["labelDesc"] as? [String: Any]
        if let rich = label?["richContent"] as? [Any] {
            guard rich.count <= 100 else { throw TaobaoTrackingError.unsupported }
            let parts = try rich.map { item -> String in
                guard let item = item as? [String: Any], let text = item["text"] as? String else { throw TaobaoTrackingError.unsupported }
                return text
            }
            let text = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        for raw in [label?["text"], node["labelDesc"] as? String, node["text"], node["desc"]] {
            if let text = raw as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    private static func status(_ title: String) -> ShipmentStatus? {
        // Only explicit semantic titles. UI progress flags such as doing/done carry no shipment status.
        switch title {
        case "待揽收", "已揽收", "揽收", "运输中": return .inTransit
        case "派送中", "正在派送": return .outForDelivery
        case "待取件", "待领取", "等待取件": return .readyForPickup
        case "已签收", "签收", "已妥投": return .delivered
        case "异常", "物流异常", "派送异常": return .exception
        default: return nil
        }
    }

    private static func dateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }

    private static func strictDate(_ text: String, format: String) -> Date? {
        let formatter = dateFormatter(format)
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    private static func timestamp(_ raw: String, now: Date) throws -> (date: Date, inferredYear: Bool) {
        for (pattern, format) in [
            (#"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"#, "yyyy-MM-dd HH:mm:ss"),
            (#"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$"#, "yyyy-MM-dd HH:mm")
        ] where raw.range(of: pattern, options: .regularExpression) != nil {
            guard let date = strictDate(raw, format: format) else { throw TaobaoTrackingError.unsupported }
            return (date, false)
        }
        guard raw.range(of: #"^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil else {
            throw TaobaoTrackingError.unsupported
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let year = calendar.component(.year, from: now)
        // Yearless events use the most recent occurrence, including December before January.
        // This is explicitly labelled an inference in stored text, not claimed as server precision.
        for candidate in [year, year - 1] {
            if let date = strictDate("\(candidate)-\(raw)", format: "yyyy-MM-dd HH:mm"), date <= now {
                return (date, true)
            }
        }
        throw TaobaoTrackingError.unsupported
    }

    private static func checkCodes(_ object: [String: Any]) throws {
        guard let ret = object["ret"] as? [String] else { return }
        if ret.contains(where: { $0.contains("JUMP_302") }) { throw TaobaoTrackingError.unsupported }
        if ret.contains(where: { $0.contains("USER_VALIDATE") || $0.contains("RGV") || $0.contains("VALIDATE") }) {
            throw TaobaoTrackingError.verification
        }
        if ret.contains(where: { $0.contains("SESSION") || $0.contains("TOKEN") || $0.contains("LOGIN") }) {
            throw TaobaoTrackingError.authentication
        }
        guard !ret.isEmpty, ret.allSatisfy({ $0 == "SUCCESS" || $0.hasPrefix("SUCCESS::") }) else { throw TaobaoTrackingError.unsupported }
    }

    private static func object(from bytes: Data) throws -> [String: Any] {
        guard bytes.count <= maximumBytes, let html = String(data: bytes, encoding: .utf8) else { throw TaobaoTrackingError.unsupported }
        let regex = try NSRegularExpression(pattern: #"__ICE_SUSPENSE_LOADER__['"]\]\[['"]undefined['"]\]\s*=\s*"#)
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        guard matches.count == 1, let range = Range(matches[0].range, in: html) else { throw TaobaoTrackingError.unsupported }
        let source = Array(html[range.upperBound...].utf8)
        guard source.first == 123 else { throw TaobaoTrackingError.unsupported }
        var stack: [UInt8] = []
        var quoted = false
        var escaped = false
        for (index, byte) in source.enumerated() {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            switch byte {
            case 34: quoted = true
            case 123, 91:
                stack.append(byte)
                guard stack.count <= maximumDepth else { throw TaobaoTrackingError.unsupported }
            case 125, 93:
                guard let opening = stack.popLast(), (opening == 123 && byte == 125) || (opening == 91 && byte == 93) else {
                    throw TaobaoTrackingError.unsupported
                }
                if stack.isEmpty {
                    let json = Data(source[...index])
                    guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw TaobaoTrackingError.unsupported }
                    return object
                }
            default: break
            }
        }
        throw TaobaoTrackingError.unsupported
    }
}
