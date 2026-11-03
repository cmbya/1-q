import Foundation
import CoreFoundation

// Independently implemented from the public PC protocol described by
// zsdd2/kdyzm@b13c0527cb38f3aad79cacf8ca85efacaa0004ed/docs/jd-integration-3.1.9.md.
// No upstream source copied. PC thor is never converted into a mobile credential.
struct JDPCClient {
    let cookies: [TaobaoTrialCookie]
    var network: any AINetworking = AISecureNetwork()
    var diagnosticLog: DiagnosticLog = .shared
    var now: () -> Date = { Date() }

    @discardableResult
    func verifySession() async throws -> [TaobaoTrialCookie] {
        try await perform(.jdVerify, seconds: 20) { session in
            _ = try await session.orders(page: 1)
            guard MallSession.hasJDPCSession(session.cookies) else { throw MallWebError.authentication }
            return session.cookies
        }
    }
    func fetchOrders() async throws -> [MallCandidate] {
        try await fetchOrderReport().candidates
    }
    func fetchOrderReport() async throws -> JDOrderImportReport {
        try await perform(.jdFetch, seconds: 30) { session in
            let policy = JDOrderImportPolicy(now: now())
            var report = JDOrderImportReport()
            var seen = Set<String>()
            var eligibleOrders: [JDPCParser.Order] = []
            // Lists first: twenty local-delivery rows must not hide an older completed shopping order.
            for page in 1...JDOrderImportPolicy.maxPages {
                try Task.checkCancellation()
                if ProcessInfo.processInfo.systemUptime >= session.deadline {
                    if page == 1 { throw MallWebError.timeout }
                    report.limited = true; break
                }
                let response: JDPCParser.Page
                do { response = try await session.orders(page: page) }
                catch {
                    try Task.checkCancellation()
                    guard page > 1, JDOrderImportPolicy.isTimeout(error) else { throw error }
                    report.limited = true; break
                }
                if response.orders.isEmpty {
                    if let total = response.totalNum, seen.count < total { report.limited = true }
                    break
                }
                var added = 0
                for order in response.orders where seen.insert(order.id).inserted {
                    added += 1
                    if report.consider(submittedAt: order.submittedAt, excluded: order.excluded, policy: policy) {
                        eligibleOrders.append(order)
                    }
                }
                if added == 0 { report.limited = true; break }
                if let total = response.totalNum, seen.count >= total { break }
                // No sort-order assumption: an old date does not prove later pages are old.
                if page == JDOrderImportPolicy.maxPages { report.limited = true }
            }
            for (index, order) in eligibleOrders.enumerated() {
                try Task.checkCancellation()
                guard index < JDOrderImportPolicy.maxDetails,
                      ProcessInfo.processInfo.systemUptime < session.deadline else { report.limited = true; break }
                let parcels: [MallWebDetail]
                do { parcels = try await session.parcels(orderID: order.id) }
                catch {
                    try Task.checkCancellation()
                    guard JDOrderImportPolicy.isTimeout(error) else { throw error }
                    report.limited = true; break
                }
                try report.append(parcels, orderID: order.id, title: order.title,
                    url: "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=\(order.id)")
            }
            report.logSummary(session.diagnostics)
            return report
        }
    }
    func query(orderID: String, trackingNumber: String) async throws -> UAPITrackingResult {
        try await perform(.jdQuery, seconds: 20) { session in
            guard Shipment.validPlatformOrderID(orderID, platform: "jd"), MallWebParser.waybill(trackingNumber) else { throw MallWebError.identityMismatch }
            // The account-authenticated detail response is scoped by this exact order ID.
            // Unlike the web reader, older orders need not appear on the current list page.
            let matches = try await session.parcels(orderID: orderID).filter { $0.number == trackingNumber }
            guard matches.count == 1, let parcel = matches.first else { throw MallWebError.identityMismatch }
            return try parcel.result(expected: trackingNumber, platform: .jd)
        }
    }
    private func perform<T>(_ stage: DiagnosticStage, seconds: TimeInterval,
                            operation: (JDPCSession) async throws -> T) async throws -> T {
        let diagnostics = JDDiagnostics(stage, log: diagnosticLog)
        let generation = MallSession.generation(for: .jd)
        do {
            diagnostics.begin(.credential)
            try Task.checkCancellation()
            guard cookies.allSatisfy({ MallSession.valid($0, platform: .jd) }), MallSession.hasJDPCSession(cookies) else { throw MallWebError.authentication }
            let session = JDPCSession(cookies: cookies, network: network, diagnostics: diagnostics,
                                      deadline: ProcessInfo.processInfo.systemUptime + seconds)
            let result = try await operation(session)
            try Task.checkCancellation()
            try MallSession.withGeneration(platform: .jd, expected: generation) {
                // Verification returns fresh credentials to the explicit save UI.
                // Cancelling verification must not silently replace a saved session.
                if stage != .jdVerify {
                    _ = try MallSession(platform: .jd).saveRotated(session.cookies, replacing: cookies, expectedGeneration: generation)
                }
            }
            diagnostics.finish(); return result
        } catch {
            let stage = diagnostics.trace.stage ?? .preflight
            diagnostics.fail(error)
            if error is CancellationError { throw CancellationError() }
            let reason: DiagnosticReason = (stage == .jdOrdersParse || stage == .jdLogisticsParse) && (error as? MallWebError) == .unsupported ? .parse : JDDiagnostics.reason(error)
            throw JDLoggedError(reason: reason, stage: stage)
        }
    }
}

private final class JDPCSession {
    var cookies: [TaobaoTrialCookie]
    let network: any AINetworking
    let diagnostics: JDDiagnostics
    let deadline: TimeInterval
    init(cookies: [TaobaoTrialCookie], network: any AINetworking, diagnostics: JDDiagnostics, deadline: TimeInterval) {
        self.cookies = cookies; self.network = network; self.diagnostics = diagnostics; self.deadline = deadline
    }
    func orders(page: Int) async throws -> JDPCParser.Page {
        let root = try await request(detail: false, body: ["page": page, "d": 1, "s": 4096])
        diagnostics.begin(.jdOrdersParse)
        let values = try JDPCParser.page(root)
        diagnostics.event(.jdResponseAccepted, counts: [.rows: values.orders.count])
        return values
    }
    func parcels(orderID: String) async throws -> [MallWebDetail] {
        guard Shipment.validPlatformOrderID(orderID, platform: "jd") else { throw MallWebError.identityMismatch }
        let root = try await request(detail: true, body: ["orderId": orderID])
        diagnostics.begin(.jdLogisticsParse)
        let values = try JDPCParser.parcels(root, orderID: orderID)
        diagnostics.event(.jdResponseAccepted, counts: [.rows: values.count])
        return values
    }
    private func request(detail: Bool, body: [String: Any]) async throws -> [String: Any] {
        diagnostics.begin(detail ? .jdLogisticsPage : .jdOrdersPage)
        try Task.checkCancellation()
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw MallWebError.timeout }
        var components = URLComponents(string: "https://api.m.jd.com/api")!
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else { throw MallWebError.unsupported }
        components.queryItems = [URLQueryItem(name: "appid", value: detail ? "details-jd-com" : "order-jd-com"),
            .init(name: "client", value: "pc"), .init(name: "clientVersion", value: "1.0.0"),
            .init(name: "loginType", value: "3"), .init(name: "t", value: String(Int64(Date().timeIntervalSince1970 * 1000))),
            .init(name: "functionId", value: detail ? "pcdetail_traceMultiPackage" : "pcorder_center_list")]
        if detail { components.queryItems?.append(.init(name: "body", value: json)) }
        guard let url = components.url, url.scheme == "https", url.host == "api.m.jd.com", url.path == "/api" else { throw MallWebError.unsupported }
        let applicable = cookies.filter { MallSession.applies($0, to: url, platform: .jd) }
        guard MallSession.hasJDPCSession(applicable), applicable.count <= 200,
              applicable.allSatisfy({ cookie in
                  MallSession.valid(cookie, platform: .jd) && cookie.name.utf8.allSatisfy { (33...126).contains($0) && ![UInt8(34),40,41,44,47,58,59,60,61,62,63,64,91,92,93,123,125].contains($0) }
                  && cookie.value.utf8.allSatisfy { (33...126).contains($0) && ![UInt8(34),44,59,92].contains($0) }
              }) else { throw MallWebError.authentication }
        let header = applicable.map { $0.name + "=" + $0.value }.joined(separator: "; ")
        guard header.utf8.count <= 64_000 else { throw MallWebError.authentication }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(20, remaining))
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue(header, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue(detail ? "https://details.jd.com" : "https://order.jd.com", forHTTPHeaderField: "Origin")
        request.setValue(detail ? "https://details.jd.com/" : "https://order.jd.com/center/list.action", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !detail {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            guard let encoded = json.addingPercentEncoding(withAllowedCharacters: allowed) else { throw MallWebError.unsupported }
            request.httpBody = Data(("body=" + encoded).utf8)
        }
        let dataResponse: Data, response: URLResponse
        do {
            let outgoing = request
            let requestTask = Task { try await network.data(for: outgoing) }
            let deadlineTask = Task {
                do { try await Task.sleep(nanoseconds: UInt64(min(20, remaining) * 1_000_000_000)); requestTask.cancel() }
                catch { }
            }
            defer { deadlineTask.cancel() }
            do {
                (dataResponse, response) = try await withTaskCancellationHandler(operation: {
                    try await requestTask.value
                }, onCancel: { requestTask.cancel() })
            } catch {
                if !Task.isCancelled && (ProcessInfo.processInfo.systemUptime >= deadline || error is CancellationError || (error as? URLError)?.code == .cancelled) { throw MallWebError.timeout }
                throw error
            }
        }
        catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            var counts: [DiagnosticMetric: Int] = [:]
            if let code = JDDiagnostics.safeNetworkCode(error) { counts[.errorCode] = code }
            let reason: DiagnosticReason = ((error as? MallWebError) == .timeout || (error as? URLError)?.code == .timedOut) ? .timeout : .network
            diagnostics.event(.jdNavigationFailed, reason: reason, counts: counts)
            throw JDLoggedError(reason: reason, stage: diagnostics.trace.stage ?? .request)
        }
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw MallWebError.timeout }
        guard let http = response as? HTTPURLResponse else { throw MallWebError.unsupported }
        diagnostics.event(.jdNetworkResponse, counts: [.httpStatus: http.statusCode, .bytes: dataResponse.count])
        guard response.url == url else { throw MallWebError.authentication }
        if http.statusCode == 401 || (300...399).contains(http.statusCode) { throw MallWebError.authentication }
        if [403,429].contains(http.statusCode) { throw MallWebError.verification }
        guard (200...299).contains(http.statusCode), dataResponse.count <= 5 * 1024 * 1024,
              response.expectedContentLength <= 5 * 1024 * 1024 else { throw MallWebError.unsupported }
        diagnostics.begin(detail ? .jdLogisticsParse : .jdOrdersParse)
        guard let root = (try? JSONSerialization.jsonObject(with: dataResponse)) as? [String: Any] else { throw MallWebError.unsupported }
        if JDPCParser.text(root["code"]) == "3" { throw MallWebError.authentication }
        if root["success"] as? Bool == false || (root["code"] != nil && JDPCParser.text(root["code"]) != "0") {
            throw JDLoggedError(reason: .unsupported, stage: diagnostics.trace.stage ?? .response)
        }
        // Honor server rotation within this operation without logging values or using a global jar.
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let name = pair.key as? String, let value = pair.value as? String { result[name] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            let saved = TaobaoTrialCookie(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                secure: cookie.isSecure, expires: cookie.expiresDate, httpOnly: cookie.isHTTPOnly)
            guard MallSession.structurallyValid(saved, platform: .jd) else { continue }
            cookies.removeAll { $0.name == saved.name && $0.domain == saved.domain && $0.path == saved.path }
            if MallSession.valid(saved, platform: .jd) { cookies.append(saved) }
        }
        return root
    }
}

enum JDPCParser {
    struct Order { let id: String; let title: String; let submittedAt: Date?; let excluded: Bool }
    struct Page { let orders: [Order]; let totalNum: Int? }
    static func page(_ root: [String: Any]) throws -> Page {
        let values = try orders(root)
        let data = root["data"] as? [String: Any] ?? [:]
        let total: Int?
        if let raw = data["totalNum"] {
            let value = text(raw)
            guard value.range(of: #"^[0-9]{1,9}$"#, options: .regularExpression) != nil,
                  let count = Int(value) else { throw MallWebError.unsupported }
            total = count
        } else { total = nil }
        return Page(orders: values, totalNum: total)
    }
    static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return ""
    }
    static func orders(_ root: [String: Any]) throws -> [Order] {
        guard root["success"] as? Bool == true, let data = root["data"] as? [String: Any],
              let rows = data["orderList"] as? [[String: Any]], rows.count <= 200 else { throw MallWebError.unsupported }
        var result: [Order] = []
        for row in rows {
            let id = text(row["orderId"])
            guard Shipment.validPlatformOrderID(id, platform: "jd"), !result.contains(where: { $0.id == id }),
                  let status = row["statusInfo"] as? [String: Any], let name = status["orderStateName"] as? String,
                  name.utf8.count <= 1000, let goods = row["wareList"] as? [[String: Any]], goods.count <= 200 else { throw MallWebError.unsupported }
            let title = goods.compactMap { $0["name"] as? String }.joined(separator: "、")
            // Product names (including 配送) do not determine the business kind.
            let evidence = [name, text(row["orderTypeName"])].joined(separator: " ")
            let excluded = JDOrderImportPolicy.excluded(orderType: text(row["orderType"]),
                allVirtual: !goods.isEmpty && goods.allSatisfy { text($0["wareType"]) == "1" }, evidence: evidence)
            result.append(Order(id: id, title: title.isEmpty ? "京东订单" : String(title.prefix(200)),
                submittedAt: JDOrderImportPolicy.submittedDate(row["dateSubmit"]), excluded: excluded))
        }
        return result
    }
    static func parcels(_ root: [String: Any], orderID: String) throws -> [MallWebDetail] {
        if let returned = root["orderId"], text(returned) != orderID { throw MallWebError.identityMismatch }
        guard let rows = root["multiPackageTrackInfoList"] as? [[String: Any]], rows.count <= 40 else { throw MallWebError.unsupported }
        var parcels: [[String: Any]] = []
        for row in rows {
            let group = row["trackGroupInfo"] as? [String: Any] ?? [:]
            let carriage = row["carriageInfo"] as? [String: Any] ?? group["orderCarriageInfo"] as? [String: Any] ?? [:]
            let number = text(carriage["carriageId"])
            if number.isEmpty { continue } // No real waybill means no importable parcel, never use the order ID.
            guard let steps = group["orderTrackShowList"] as? [[String: Any]], steps.count <= 300 else { throw MallWebError.unsupported }
            let points: [[String: Any]] = steps.map { step in
                ["time": step["CreationTime"] ?? "", "text": [text(step["StatusName"]), text(step["Content"])].filter { !$0.isEmpty }.joined(separator: "：")]
            }
            parcels.append(["number": number, "carrier": text(carriage["carrier"]), "points": points])
        }
        return try JDPageParser.parcels(["kind": "logistics", "recognized": true, "orderID": orderID, "parcels": parcels], orderID: orderID)
    }
}
