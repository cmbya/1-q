import Foundation
import CoreFoundation

/*
 Portions adapted from dsh-parcel-tracker (MIT License).
 Copyright (c) 2026 Lyybutterflies

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
 */

// Protocol/field provenance (MIT): Lyybutterflies/dsh-parcel-tracker,
// commit 585111e14563a35ea62fb062aad9b0675739c79b, lib/platforms/pdd.js
// and scripts/test-pdd.mjs. No signing bypass, browser automation or retries.
// Never infer delivered from historical or forecast prose.
struct MallDirectError: LocalizedError {
    let reason: MallWebError
    let stage: String
    let http: Int?
    let bytes: Int?
    let code: String?
    var stopsBatch: Bool { reason.stopsBatch }
    init(reason: MallWebError, stage: String, http: Int? = nil, bytes: Int? = nil, code: String? = nil) {
        self.reason = reason
        self.stage = ["credentials", "pdd-list", "pdd-trace", "identity"].contains(stage) ? stage : "identity"
        self.http = http.flatMap { (100...599).contains($0) ? $0 : nil }
        self.bytes = bytes.flatMap { $0 >= 0 ? $0 : nil }
        // Never echo arbitrary server strings, even if they look like an error code.
        self.code = code.flatMap { ["0", "3", "202", "1001", "1002", "401", "403", "429"].contains($0) ? $0 : nil }
    }
    var errorDescription: String? {
        var fields = ["阶段=\(stage)"]
        if let http { fields.append("HTTP=\(http)") }
        if let bytes { fields.append("字节=\(bytes)") }
        if let code { fields.append("代码=\(code)") }
        let explanation = reason == .unsupported ? "商城接口拒绝请求或返回结构不受支持；未更新数据，未切换UAPI。" : (reason.errorDescription ?? "商城请求失败。")
        return explanation + "（" + fields.joined(separator: "，") + "）"
    }
}

struct MallDirectClient {
    let platform: MallPlatform
    let cookies: [TaobaoTrialCookie]
    let network: any AINetworking
    init(platform: MallPlatform, cookies: [TaobaoTrialCookie], network: any AINetworking = AISecureNetwork()) {
        self.platform = platform; self.cookies = cookies; self.network = network
    }
    func verifySession() async throws { _ = try await orders() }

    func fetchOrders() async throws -> [MallCandidate] {
        let list = try await orders()
        var result: [MallCandidate] = []
        // Fixed first page only. Same bounded per-order request budget as DSH.
        for order in list.filter({ pending($0) }).prefix(8) {
            try Task.checkCancellation()
            let id = text(order["orderSn"])
            guard MallWebParser.identifier(id, platform: platform) else { throw failure(.identityMismatch, "identity") }
            let name = title(order)
            let number = text(order["trackingNumber"])
            guard MallWebParser.waybill(number) else { throw failure(.noTrace, "pdd-list") }
            var carrier = ""
            do {
                let ship = try await pddShipping(order)
                carrier = bounded(ship["shippingName"], 100)
            }
            catch let error as MallDirectError where error.reason == .noTrace {
                // The list's real waybill is still importable; no tracking result is fabricated.
            }
            try append(MallCandidate(trackingNumber: number, carrier: carrier, title: name, orderID: id), to: &result)
        }
        return result
    }

    func query(orderID: String, trackingNumber: String) async throws -> UAPITrackingResult {
        guard MallWebParser.identifier(orderID, platform: platform), MallWebParser.waybill(trackingNumber) else { throw failure(.identityMismatch, "identity") }
        // Metadata is deliberately not persisted in MallCandidate. Re-read the fixed first page;
        // older orders falling off that page cannot be refreshed, rather than guessing metadata.
        // Do not filter signed orders here: an existing imported parcel can still be refreshed.
        let list = try await orders()
        let matches = list.filter { text($0["orderSn"]) == orderID && text($0["trackingNumber"]) == trackingNumber }
        guard !matches.isEmpty else { throw failure(.noTrace, "pdd-list") }
        guard matches.count == 1, let order = matches.first else { throw failure(.identityMismatch, "identity") }
        return try tracking(try await pddShipping(order), expected: trackingNumber)
    }

    private func failure(_ reason: MallWebError, _ stage: String) -> MallDirectError { .init(reason: reason, stage: stage) }
    private func text(_ value: Any?) -> String {
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return ""
    }
    private func bounded(_ value: Any?, _ limit: Int) -> String { String(text(value).prefix(limit)) }
    private func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    private func array(_ value: Any?, stage: String) throws -> [[String: Any]] {
        guard let items = value as? [[String: Any]], items.count <= 500 else { throw failure(.unsupported, stage) }
        return items
    }
    private func append(_ candidate: MallCandidate, to result: inout [MallCandidate]) throws {
        if let old = result.first(where: { $0.trackingNumber == candidate.trackingNumber }) {
            guard old.orderID == candidate.orderID else { throw failure(.identityMismatch, "identity") }
        } else { result.append(candidate) }
    }
    private func title(_ order: [String: Any]) -> String {
        let goods = order["orderGoods"] as? [[String: Any]] ?? []
        var names: [String] = []
        for item in goods {
            let name = text(item["goodsName"])
            if !name.isEmpty, !names.contains(name) { names.append(String(name.prefix(200))) }
            if names.count == 2 { break }
        }
        return names.isEmpty ? platform.title + "订单" : String(names.joined(separator: "、").prefix(200))
    }
    private func pending(_ order: [String: Any]) -> Bool {
        guard !text(order["trackingNumber"]).isEmpty else { return false }
        let prompt = text(order["orderStatusPrompt"])
        if ["交易成功", "已评价", "已取消", "交易关闭", "已退款", "退款成功", "待付款", "等待付款"].contains(where: prompt.contains) { return false }
        let hint = dictionary(dictionary(order["extraInfo"])?["orderHint"])
        let metric = text(dictionary(hint?["metricInfo"])?["expressStatus"])
        let status = metric.isEmpty ? text(dictionary(hint?["extraMap"])?["pddStatus"]) : metric
        return !["SIGN", "SIGNED"].contains(status.uppercased())
    }
    private var pddListURL: URL {
        var url = URLComponents(string: "https://mobile.yangkeduo.com/orders.html")!
        url.queryItems = [URLQueryItem(name: "type", value: "0"), URLQueryItem(name: "comment_tab", value: "1"), URLQueryItem(name: "combine_orders", value: "1"), URLQueryItem(name: "main_orders", value: "1")]
        return url.url!
    }
    private func orders() async throws -> [[String: Any]] {
        let root = try await request(pddListURL, stage: "pdd-list")
        guard let store = dictionary(root["ordersStore"]) ?? dictionary(root["store"]) else { throw failure(.unsupported, "pdd-list") }
        return try array(store["orders"], stage: "pdd-list")
    }
    private func pddShipping(_ order: [String: Any]) async throws -> [String: Any] {
        let id = text(order["orderSn"]), number = text(order["trackingNumber"]), shippingID = text(order["shippingId"])
        guard MallWebParser.identifier(id, platform: .pdd), MallWebParser.waybill(number) else { throw failure(.identityMismatch, "pdd-trace") }
        guard !shippingID.isEmpty, shippingID.count <= 100, shippingID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw failure(.noTrace, "pdd-trace") }
        var url = URLComponents(string: "https://mobile.yangkeduo.com/goods_express.html")!
        url.queryItems = [URLQueryItem(name: "order_sn", value: id), URLQueryItem(name: "tracking_number", value: number), URLQueryItem(name: "shipping_id", value: shippingID), URLQueryItem(name: "hide_address", value: "1")]
        let root = try await request(url.url!, stage: "pdd-trace")
        guard let store = dictionary(root["store"]), let trace = dictionary(store["traceData"]) else { throw failure(.unsupported, "pdd-trace") }
        guard let ship = dictionary(trace["shipping"]) else { throw failure(.noTrace, "pdd-trace") }
        guard !text(ship["trackingNumber"]).isEmpty else { throw failure(.noTrace, "pdd-trace") }
        guard text(ship["trackingNumber"]) == number else { throw failure(.identityMismatch, "pdd-trace") }
        return ship
    }
    private func cookieHeader(for url: URL) throws -> String {
        let applicable = cookies.filter { MallSession.applies($0, to: url, platform: platform) }
        guard !applicable.isEmpty, applicable.count <= 200 else { throw failure(.authentication, "credentials") }
        for cookie in applicable {
            guard MallSession.valid(cookie, platform: platform), cookie.name.utf8.allSatisfy({ (33...126).contains($0) && ![UInt8(34), 40, 41, 44, 47, 58, 59, 60, 61, 62, 63, 64, 91, 92, 93, 123, 125].contains($0) }),
                  cookie.value.utf8.allSatisfy({ (33...126).contains($0) && $0 != 34 && $0 != 44 && $0 != 59 && $0 != 92 }) else { throw failure(.authentication, "credentials") }
        }
        let names = Set(applicable.filter { !$0.value.isEmpty }.map(\.name))
        guard names.contains("PDDAccessToken") && (names.contains("pdd_user_id") || names.contains("pdduid")) else { throw failure(.authentication, "credentials") }
        let header = applicable.map { $0.name + "=" + $0.value }.joined(separator: "; ")
        guard header.utf8.count <= 64_000 else { throw failure(.authentication, "credentials") }
        return header
    }
    private func request(_ url: URL, stage: String) async throws -> [String: Any] {
        try Task.checkCancellation()
        // URLs are built internally only. Network's default transport refuses all redirects.
        guard platform.allowed(url), url.host == "mobile.yangkeduo.com", ["/orders.html", "/goods_express.html"].contains(url.path) else { throw failure(.unsupported, stage) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.httpMethod = "GET"
        request.setValue(try cookieHeader(for: url), forHTTPHeaderField: "Cookie")
        request.setValue(platform.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue(stage == "pdd-list" ? "https://mobile.yangkeduo.com/personal.html" : pddListURL.absoluteString, forHTTPHeaderField: "Referer")
        let data: Data, response: URLResponse
        do { (data, response) = try await network.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw failure((error as? URLError)?.code == .timedOut ? .timeout : .unsupported, stage)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw failure(.unsupported, stage) }
        func rejected(_ reason: MallWebError, code: String? = nil) -> MallDirectError {
            .init(reason: reason, stage: stage, http: http.statusCode, bytes: data.count, code: code)
        }
        guard response.url == url else { throw rejected(.authentication) }
        guard data.count <= 2_000_000, response.expectedContentLength <= 2_000_000 else { throw rejected(.unsupported) }
        if http.statusCode == 401 || (300...399).contains(http.statusCode) { throw rejected(.authentication) }
        if [403, 429].contains(http.statusCode) { throw rejected(.verification) }
        guard (200...299).contains(http.statusCode) else { throw rejected(.unsupported) }
        guard let content = String(data: data, encoding: .utf8) else { throw rejected(.unsupported) }
        if let pageError = MallWebParser.pageFailure(url: url, text: content) { throw rejected(pageError) }
        let root: [String: Any]
        guard let object = Self.rawData(content) else {
            let login = content.contains("PDDAccessToken") == false && (content.contains("请先登录") || content.contains("请登录") || content.contains("login.html"))
            throw rejected(login ? .authentication : .unsupported)
        }
        root = object
        let code = text(root["code"]), errorCode = text(root["errCode"])
        let failureCode = !errorCode.isEmpty ? errorCode : code
        if root["success"] as? Bool == false || (!code.isEmpty && code != "0") || (!errorCode.isEmpty && errorCode != "0") {
            let reason: MallWebError = ["1001", "1002", "401"].contains(failureCode) ? .authentication : ["403", "429"].contains(failureCode) ? .verification : .unsupported
            throw rejected(reason, code: failureCode)
        }
        return root
    }
    // Strict assignment plus balanced object/string scanner. No JS evaluation, regex JSON
    // capture, arbitrary URL following, or scanning forward from a non-assignment marker.
    private static func rawData(_ html: String) -> [String: Any]? {
        let bytes = Array(html.utf8), marker = Array("window.rawData".utf8)
        guard bytes.count >= marker.count else { return nil }
        func whitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
        for start in 0...(bytes.count - marker.count) {
            guard Array(bytes[start..<(start + marker.count)]) == marker else { continue }
            if start > 0 {
                let previous = bytes[start - 1]
                if (48...57).contains(previous) || (65...90).contains(previous) || (97...122).contains(previous) || [36, 46, 95].contains(previous) { continue }
            }
            var index = start + marker.count
            while index < bytes.count && whitespace(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] == 61 else { continue }
            index += 1
            while index < bytes.count && whitespace(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] == 123 else { continue }
            let objectStart = index
            var depth = 0, inString = false, escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if inString {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { inString = false }
                } else if byte == 34 { inString = true }
                else if byte == 123 { depth += 1; if depth > 100 { return nil } }
                else if byte == 125 {
                    depth -= 1
                    if depth == 0 {
                        return (try? JSONSerialization.jsonObject(with: Data(bytes[objectStart...index]))) as? [String: Any]
                    }
                }
                index += 1
            }
            return nil
        }
        return nil
    }
    private func date(_ value: Any?) -> Date? {
        if let parsed = MallWebParser.date(value) { return parsed }
        if let string = value as? String, string.range(of: #"^[0-9]{10,13}$"#, options: .regularExpression) != nil, let number = Double(string) {
            return MallWebParser.date(NSNumber(value: number))
        }
        return nil
    }
    private func tracking(_ ship: [String: Any], expected: String) throws -> UAPITrackingResult {
        let stage = "pdd-trace"
        let number = text(ship["trackingNumber"])
        guard !number.isEmpty else { throw failure(.noTrace, stage) }
        guard number == expected else { throw failure(.identityMismatch, stage) }
        guard let raw = ship["traces"] else { throw failure(.noTrace, stage) }
        let nodes = try array(raw, stage: stage)
        guard !nodes.isEmpty else { throw failure(.noTrace, stage) }
        var points: [MallWebPoint] = [], total = 0
        for node in nodes {
            let description = ["info", "statusTag", "status"].map { text(node[$0]) }.first(where: { !$0.isEmpty }) ?? ""
            let time: Date? = date(node["displayTime"]) ?? date(node["time"])
            guard let time, !description.isEmpty else { throw failure(.noTrace, stage) }
            total += description.utf8.count
            guard total <= 200_000 else { throw failure(.unsupported, stage) }
            points.append(MallWebPoint(date: time, text: String(description.prefix(1000))))
        }
        let sorted = points.sorted { $0.date > $1.date }
        guard let latest = sorted.first else { throw failure(.noTrace, stage) }
        // Prefer explicit platform terminal flags; otherwise classify only the latest dated event.
        // Cabinet storage and forecast/negated text must not become collected.
        let status: ShipmentStatus? = ["SIGN", "SIGNED"].contains(text(ship["shippingStatus"]).uppercased()) ? .delivered : MallDeliveryState.resolve(latest: latest.text)
        let summary = (["\(platform.title)Cookie直连物流（非UAPI）"] + sorted.map { ShipmentDateDisplay.string($0.date) + " " + $0.text }).joined(separator: "\n")
        guard summary.utf8.count <= 250_000 else { throw failure(.unsupported, stage) }
        return UAPITrackingResult(trackingNumber: number, carrierName: bounded(ship["shippingName"], 100), carrierCode: "", status: status, logisticsInfo: latest.text, logisticsTime: latest.date, queryInfo: summary, queriedAt: Date())
    }
}
