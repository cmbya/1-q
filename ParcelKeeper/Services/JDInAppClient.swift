import Foundation
import WebKit
import UIKit

// Independent implementation of publicly observed JD page behaviour.
// Mobile pages initiate their own requests; PC Cookie operations dispatch separately to JDPCClient.
// No signing emulation, password/SMS automation, credential bridge or paid fallback.
struct JDInAppClient {
    let cookies: [TaobaoTrialCookie]
    var diagnosticLog: DiagnosticLog = .shared
    var browserStore: WKWebsiteDataStore? = nil
    var now: () -> Date = { Date() }

    func verifySession() async throws {
        if browserStore == nil && MallSession.hasJDPCSession(cookies) { try await JDPCClient(cookies: cookies, diagnosticLog: diagnosticLog).verifySession(); return }
        let diagnostics = JDDiagnostics(.jdVerify, log: diagnosticLog)
        do {
            let page = try await JDPageBrowser(cookies: cookies, diagnostics: diagnostics, browserStore: browserStore).read(url: MallPlatform.jd.ordersURL, orderID: nil)
            _ = try JDPageParser.orders(page)
            // Verification never automatically persists rotated credentials.
            diagnostics.finish()
        }
        catch { diagnostics.fail(error); throw error }
    }

    func fetchOrders() async throws -> [MallCandidate] {
        try await fetchOrderReport().candidates
    }
    func fetchOrderReport() async throws -> JDOrderImportReport {
        if browserStore == nil && MallSession.hasJDPCSession(cookies) {
            return try await JDPCClient(cookies: cookies, diagnosticLog: diagnosticLog, now: now).fetchOrderReport()
        }
        let diagnostics = JDDiagnostics(.jdFetch, log: diagnosticLog)
        let generation = MallSession.generation(for: .jd)
        let store = await operationStore()
        do {
            let outcome = try await collectOrders(store: store, diagnostics: diagnostics)
            let report = outcome.report
            try Task.checkCancellation()
            if outcome.rotationSafe && report.detailFailed == 0 && report.stoppedReason == nil {
                try await persistRotation(store: store, generation: generation)
            }
            try MallSession.withGeneration(platform: .jd, expected: generation) { try Task.checkCancellation() }
            report.logSummary(diagnostics)
            diagnostics.finish(); return report
        } catch { diagnostics.fail(error); throw error }
    }
    private func collectOrders(store: WKWebsiteDataStore, diagnostics: JDDiagnostics) async throws -> (report: JDOrderImportReport, rotationSafe: Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        let policy = JDOrderImportPolicy(now: now())
        var report = JDOrderImportReport()
        // Real next links still do not prove full mobile history coverage. No invented
        // pagination API, scrolling selectors, signatures, date fields or total claims.
        report.limited = true
        var next: URL? = MallPlatform.jd.ordersURL
        var visited = Set<String>(), seen = Set<String>(), blocked = Set<String>()
        var detailReads = 0, dateReads = 0
        var rotationSafe = true
        for _ in 0..<JDOrderImportPolicy.maxPages {
            try Task.checkCancellation()
            guard let url = next, visited.insert(url.absoluteString).inserted,
                  ProcessInfo.processInfo.systemUptime < deadline else { break }
            let page: [String: Any]
            let list: [JDPageParser.Order]
            do {
                page = try await JDPageBrowser(cookies: cookies, diagnostics: diagnostics, browserStore: store).read(url: url, orderID: nil, operationDeadline: deadline)
                diagnostics.begin(.jdOrdersParse)
                list = try JDPageParser.orders(page)
            } catch {
                if error is CancellationError { throw error }
                if seen.isEmpty { throw error }
                report.stoppedReason = JDDiagnostics.reason(error); break
            }
            diagnostics.event(.jdResponseAccepted, counts: [.rows: list.count])
            next = JDPageParser.nextURL(page)
            for var order in list where seen.insert(order.id).inserted {
                try Task.checkCancellation()
                // Supplement BEFORE consider(): unknown dates must not be filtered first.
                if order.submittedAt == nil, !order.excluded, let dateURL = order.dateURL,
                   dateReads < JDOrderImportPolicy.maxDetails, ProcessInfo.processInfo.systemUptime < deadline {
                    dateReads += 1
                    do {
                        let datePage = try await JDPageBrowser(cookies: cookies, diagnostics: diagnostics, browserStore: store).read(url: dateURL, orderID: order.id, dateOnly: true, operationDeadline: deadline)
                        order.submittedAt = try JDPageParser.submission(datePage, orderID: order.id)
                    } catch {
                        if error is CancellationError { throw error }
                        rotationSafe = false
                        let reason = JDDiagnostics.reason(error)
                        if reason == .authentication || reason == .verification { report.stoppedReason = reason }
                        if reason == .identity { blocked.insert(order.id) }
                    }
                }
                guard report.consider(submittedAt: order.submittedAt, excluded: order.excluded, policy: policy) else {
                    if report.stoppedReason != nil { break }; continue
                }
                guard report.stoppedReason == nil else { break }
                guard !blocked.contains(order.id), detailReads < JDOrderImportPolicy.maxDetails,
                      ProcessInfo.processInfo.systemUptime < deadline else { continue }
                detailReads += 1
                do {
                    let detail = try await JDPageBrowser(cookies: cookies, diagnostics: diagnostics, browserStore: store).read(url: order.url, orderID: order.id, operationDeadline: deadline)
                    diagnostics.begin(.jdLogisticsParse)
                    let parcels = try JDPageParser.parcels(detail, orderID: order.id)
                    let conflicts = report.candidates.filter { candidate in parcels.contains { $0.number == candidate.trackingNumber } && candidate.orderID != order.id }
                    if !conflicts.isEmpty {
                        // Retract both sides of a cross-order number collision, not just the last row.
                        blocked.formUnion(conflicts.map(\.orderID)); blocked.insert(order.id)
                        // Let report register the ambiguous number before retracting whole orders.
                        try report.append(parcels, orderID: order.id, title: order.title, url: order.url.absoluteString)
                        report.candidates.removeAll { blocked.contains($0.orderID) }
                        for owner in blocked { report.recordDetailFailure(orderID: owner) }
                        rotationSafe = false
                        continue
                    }
                    try report.append(parcels, orderID: order.id, title: order.title, url: order.url.absoluteString)
                } catch {
                    if error is CancellationError { throw error }
                    rotationSafe = false
                    let reason = JDDiagnostics.reason(error)
                    if reason == .identity { blocked.insert(order.id); report.candidates.removeAll { $0.orderID == order.id } }
                    report.recordDetailFailure(orderID: order.id)
                    if reason == .authentication || reason == .verification { report.stoppedReason = reason; break }
                    // Preserve independently accepted orders on isolated parse/network failures.
                }
            }
            if report.stoppedReason != nil { break }
        }
        return (report, rotationSafe)
    }

    func query(orderID: String, trackingNumber: String, sourceURL: String? = nil) async throws -> UAPITrackingResult {
        if browserStore == nil && MallSession.hasJDPCSession(cookies) { return try await JDPCClient(cookies: cookies, diagnosticLog: diagnosticLog).query(orderID: orderID, trackingNumber: trackingNumber) }
        let diagnostics = JDDiagnostics(.jdQuery, log: diagnosticLog)
        let generation = MallSession.generation(for: .jd)
        do {
            let url = try JDPageParser.refreshURL(orderID: orderID, trackingNumber: trackingNumber, sourceURL: sourceURL)
            let store = await operationStore()
            // Account ownership comes from the authenticated exact order+waybill response,
            // not presence on today's list page or mere possession of an entry URL.
            let page = try await JDPageBrowser(cookies: cookies, diagnostics: diagnostics, browserStore: store).read(url: url, orderID: orderID, operationDeadline: ProcessInfo.processInfo.systemUptime + 20)
            diagnostics.begin(.jdLogisticsParse)
            let matches = try JDPageParser.parcels(page, orderID: orderID).filter { $0.number == trackingNumber }
            guard matches.count == 1, let parcel = matches.first else { throw MallWebError.identityMismatch }
            let result = try parcel.result(expected: trackingNumber, platform: .jd)
            try await persistRotation(store: store, generation: generation)
            diagnostics.finish(); return result
        } catch { diagnostics.fail(error); throw error }
    }

    @MainActor private func operationStore() -> WKWebsiteDataStore { browserStore ?? MallBrowserContext.store(for: .jd) }
    @MainActor private func persistRotation(store: WKWebsiteDataStore, generation: UUID) async throws {
        let native = await store.httpCookieStore.allCookies()
        try Task.checkCancellation()
        let rotated = native.map { TaobaoTrialCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, secure: $0.isSecure, expires: $0.expiresDate, httpOnly: $0.isHTTPOnly) }.filter { $0.name != "thor" && MallSession.valid($0, platform: .jd) }
        guard JDPageParser.sameAccount(cookies, rotated) else { throw MallWebError.identityMismatch }
        try MallSession.withGeneration(platform: .jd, expected: generation) {
            try Task.checkCancellation()
            // Exactly once at operation end, never once per page against the old snapshot.
            guard try MallSession(platform: .jd).saveRotated(rotated, replacing: cookies, expectedGeneration: generation) else { throw CancellationError() }
        }
    }
}

enum JDPageParser {
    struct Order {
        let id: String
        let title: String
        let status: String
        let url: URL
        var submittedAt: Date?
        let excluded: Bool
        var dateURL: URL? = nil
    }
    static func refreshURL(orderID: String, trackingNumber: String, sourceURL: String?) throws -> URL {
        guard Shipment.validPlatformOrderID(orderID, platform: "jd"), MallWebParser.waybill(trackingNumber) else { throw MallWebError.identityMismatch }
        let raw = sourceURL ?? "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=\(orderID)"
        guard let safe = Shipment.logisticsEntry(raw, orderID: orderID), let url = URL(string: safe) else { throw MallWebError.identityMismatch }
        return url
    }
    static func sameAccount(_ original: [TaobaoTrialCookie], _ current: [TaobaoTrialCookie]) -> Bool {
        func pins(_ values: [TaobaoTrialCookie]) -> Set<String> {
            Set(values.filter { $0.name == "pt_pin" && !$0.value.isEmpty && MallSession.applies($0, to: MallPlatform.jd.ordersURL, platform: .jd) }.map(\.value))
        }
        let before = pins(original), after = pins(current)
        return before.count == 1 && after == before && MallSession.hasLoginCredentials(current, platform: .jd)
    }
    static func dateURL(_ raw: String, orderID: String) -> URL? {
        guard raw.utf8.count <= 2048, let parts = URLComponents(string: raw), let url = parts.url,
              MallPlatform.jd.allowed(url), url.host == "trade.m.jd.com", url.path.hasPrefix("/order/"),
              url.path.lowercased().contains("detail"), parts.fragment == nil else { return nil }
        let items = parts.queryItems ?? []
        let ids = items.filter { ["orderId", "orderid", "dealId"].contains($0.name) }.compactMap(\.value)
        guard ids == [orderID], Shipment.validPlatformOrderID(orderID, platform: "jd"),
              !items.contains(where: { $0.name.range(of: "cookie|token|pt_|thor|password|pin", options: [.regularExpression, .caseInsensitive]) != nil }) else { return nil }
        return url
    }
    static func nextURL(_ page: [String: Any]) -> URL? {
        guard let raw = page["nextURL"] as? String, raw.utf8.count <= 2048,
              let parts = URLComponents(string: raw), let url = parts.url,
              MallPlatform.jd.allowed(url), url.host == "trade.m.jd.com", url.path == MallPlatform.jd.ordersURL.path,
              parts.fragment == nil,
              !(parts.queryItems ?? []).contains(where: { $0.name.range(of: "cookie|token|pt_|thor|password|pin", options: [.regularExpression, .caseInsensitive]) != nil }) else { return nil }
        return url
    }
    static func submission(_ page: [String: Any], orderID: String) throws -> Date? {
        try failure(page)
        guard page["kind"] as? String == "orderDate", page["recognized"] as? Bool == true else { throw MallWebError.unsupported }
        guard page["orderID"] as? String == orderID else { throw MallWebError.identityMismatch }
        return JDOrderImportPolicy.submittedDate(page["submittedAt"])
    }
    // Merge supplemental DOM data only into a structured row with exactly the same ID.
    // A conflicting trusted date fails closed rather than choosing whichever arrived first.
    static func supplement(_ page: [String: Any], snapshot: [String: Any]) throws -> [String: Any] {
        try failure(snapshot)
        let structured = try orders(page)
        guard snapshot["kind"] as? String == "orders" else { return page }
        var dom: [Order] = []
        if snapshot["recognized"] as? Bool == true { dom = try orders(snapshot) }
        var rows = page["orders"] as? [[String: Any]] ?? []
        for (index, order) in structured.enumerated() {
            guard let match = dom.first(where: { $0.id == order.id }) else { continue }
            if let a = order.submittedAt, let b = match.submittedAt, a != b { throw MallWebError.identityMismatch }
            if order.submittedAt == nil, match.submittedAt != nil {
                rows[index]["submittedAt"] = (snapshot["orders"] as? [[String: Any]])?.first(where: { $0["id"] as? String == order.id })?["submittedAt"]
            }
            if let dateURL = match.dateURL { rows[index]["dateURL"] = dateURL.absoluteString }
        }
        var result = page; result["orders"] = rows
        if let next = nextURL(snapshot) { result["nextURL"] = next.absoluteString }
        return result
    }
    static func failure(_ page: [String: Any]) throws {
        if let error = page["error"] as? String {
            if error == "authentication" { throw MallWebError.authentication }
            if error == "verification" { throw MallWebError.verification }
            if error == "identity" { throw MallWebError.identityMismatch }
            throw MallWebError.unsupported
        }
    }
    static func orders(_ page: [String: Any]) throws -> [Order] {
        try failure(page)
        guard page["kind"] as? String == "orders", page["recognized"] as? Bool == true,
              let rows = page["orders"] as? [[String: Any]], rows.count <= 200 else { throw MallWebError.unsupported }
        var result: [Order] = []
        for row in rows {
            guard let id = row["id"] as? String, Shipment.validPlatformOrderID(id, platform: "jd"),
                  let status = row["status"] as? String, status.utf8.count <= 1000,
                  let title = row["title"] as? String, title.utf8.count <= 1000,
                  let raw = row["url"] as? String,
                  let safe = Shipment.logisticsEntry(raw, orderID: id), let url = URL(string: safe) else { throw MallWebError.unsupported }
            if result.contains(where: { $0.id == id }) { throw MallWebError.identityMismatch }
            // A missing/unparseable submit date affects import statistics, not session/schema validity.
            let excluded = row["excluded"] as? Bool == true || JDOrderImportPolicy.excluded(orderType: "", allVirtual: false, evidence: status)
            result.append(Order(id: id, title: String(title.prefix(200)), status: status, url: url,
                submittedAt: JDOrderImportPolicy.submittedDate(row["submittedAt"]), excluded: excluded,
                dateURL: (row["dateURL"] as? String).flatMap { dateURL($0, orderID: id) }))
        }
        return result
    }
    static func parcels(_ page: [String: Any], orderID: String) throws -> [MallWebDetail] {
        try failure(page)
        guard page["kind"] as? String == "logistics", page["recognized"] as? Bool == true else { throw MallWebError.unsupported }
        guard page["orderID"] as? String == orderID else { throw MallWebError.identityMismatch }
        guard let rows = page["parcels"] as? [[String: Any]], rows.count <= 40 else { throw MallWebError.unsupported }
        var result: [MallWebDetail] = []
        for row in rows {
            guard let number = row["number"] as? String, MallWebParser.waybill(number),
                  let carrier = row["carrier"] as? String, carrier.utf8.count <= 400,
                  let nodes = row["points"] as? [[String: Any]], nodes.count <= 300 else { throw MallWebError.unsupported }
            guard !result.contains(where: { $0.number == number }) else { throw MallWebError.identityMismatch }
            var points: [MallWebPoint] = []
            for node in nodes {
                guard let date = MallWebParser.date(node["time"]), let text = node["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 4000 else { throw MallWebError.unsupported }
                points.append(MallWebPoint(date: date, text: String(text.prefix(1000))))
            }
            result.append(MallWebDetail(number: number, carrier: carrier, points: points))
        }
        return result
    }
}

@MainActor private final class JDPageBrowser: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    // WKUserContentController owns its handler; do not create a webview/owner cycle.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var owner: JDPageBrowser?
        init(_ owner: JDPageBrowser) { self.owner = owner }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            owner?.userContentController(controller, didReceive: message)
        }
    }
    private let cookies: [TaobaoTrialCookie]
    private var web: WKWebView?
    private var captured: [String: Any]?
    private var emptyCapture: [String: Any]?
    private var failed: Error?
    private var finished = false
    private var expectedOrder: String?
    private var dateOnly = false
    private var loggedDOM = false
    private let diagnostics: JDDiagnostics
    private let browserStore: WKWebsiteDataStore?
    init(cookies: [TaobaoTrialCookie], diagnostics: JDDiagnostics, browserStore: WKWebsiteDataStore? = nil) {
        self.cookies = cookies; self.diagnostics = diagnostics; self.browserStore = browserStore
    }

    func read(url: URL, orderID: String?, dateOnly: Bool = false, operationDeadline: TimeInterval? = nil) async throws -> [String: Any] {
        diagnostics.begin(.credential)
        try Task.checkCancellation()
        guard MallPlatform.jd.allowed(url), cookies.allSatisfy({ MallSession.valid($0, platform: .jd) }),
              MallSession.hasLoginCredentials(cookies, platform: .jd) else { throw MallWebError.authentication }
        // WebKit page execution is an app-foreground capability, not a background API.
        guard UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { throw MallWebError.unsupported }
        expectedOrder = orderID
        self.dateOnly = dateOnly
        if let orderID {
            guard (dateOnly ? JDPageParser.dateURL(url.absoluteString, orderID: orderID) != nil : Shipment.logisticsEntry(url.absoluteString, orderID: orderID) != nil) else { throw MallWebError.identityMismatch }
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = browserStore ?? MallBrowserContext.store(for: .jd)
        configuration.userContentController.add(WeakHandler(self), name: "jdCapture")
        configuration.userContentController.addUserScript(WKUserScript(source: JDPageScript.capture, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        view.customUserAgent = MallPlatform.jd.userAgent
        view.navigationDelegate = self
        view.isUserInteractionEnabled = false
        view.alpha = 0.01
        window.addSubview(view)
        web = view
        defer { cleanup() }
        return try await withTaskCancellationHandler(operation: {
            // The budget includes cookie injection, navigation, XHR capture and DOM.
            let deadline = min(ProcessInfo.processInfo.systemUptime + 12, operationDeadline ?? .greatestFiniteMagnitude)
            diagnostics.begin(.jdCookieInjection)
            let existing = await view.configuration.websiteDataStore.httpCookieStore.allCookies()
            let live = existing.map { TaobaoTrialCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, secure: $0.isSecure, expires: $0.expiresDate, httpOnly: $0.isHTTPOnly) }.filter { MallSession.valid($0, platform: .jd) }
            if live.contains(where: { $0.name == "pt_pin" }) {
                guard JDPageParser.sameAccount(cookies, live) else { throw MallWebError.identityMismatch }
            }
            for cookie in cookies {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw MallWebError.timeout }
                // Preserve cookies rotated by the live login/order page. A stored
                // snapshot must not overwrite this browser context's newer session.
                if existing.contains(where: { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path && ($0.expiresDate.map { $0 > Date() } ?? true) }) { continue }
                guard let native = cookie.webCookie() else { throw MallWebError.authentication }
                var installed = false
                view.configuration.websiteDataStore.httpCookieStore.setCookie(native) { installed = true }
                while !installed {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw MallWebError.timeout }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            diagnostics.begin(orderID == nil ? .jdOrdersPage : .jdLogisticsPage)
            view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            var lastSnapshot: [String: Any]?
            // Leave callback headroom inside the hard deadline; do not begin a DOM
            // evaluation at the last instant and discard already captured split data.
            while ProcessInfo.processInfo.systemUptime + 0.3 < deadline {
                try Task.checkCancellation()
                if let failed { throw failed }
                // Do not return the first numbered response. Keep the full bounded
                // capture window for later split parcels and still-running requests.
                if let captured { try JDPageParser.failure(captured) }
                if finished {
                    guard let current = view.url, MallPlatform.jd.allowed(current) else { throw MallWebError.unsupported }
                    if let failure = MallWebParser.pageFailure(url: current, text: "") { throw failure }
                    if !loggedDOM { diagnostics.begin(.jdPageDOM) }
                    var evaluated = false
                    var value: Any?
                    var scriptFailed = false
                    view.evaluateJavaScript("window.__parcelJDSnapshot ? window.__parcelJDSnapshot() : null") { output, error in
                        value = output; scriptFailed = error != nil; evaluated = true
                    }
                    while !evaluated {
                        try Task.checkCancellation()
                        guard ProcessInfo.processInfo.systemUptime < deadline else { throw MallWebError.timeout }
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                    if scriptFailed {
                        diagnostics.event(.jdScriptFailed, reason: .parse)
                        throw JDLoggedError(reason: .parse, stage: .jdPageDOM)
                    }
                    if let snapshot = value as? [String: Any] {
                        if !loggedDOM || snapshot["recognized"] as? Bool == true {
                            diagnostics.event(.jdPageDOMResult, counts: [.accepted: snapshot["recognized"] as? Bool == true ? 1 : 0])
                        }
                        loggedDOM = true
                        try JDPageParser.failure(snapshot)
                        lastSnapshot = snapshot
                        if dateOnly, snapshot["recognized"] as? Bool == true {
                            guard let orderID, snapshot["orderID"] as? String == orderID,
                                  let current = view.url, JDPageParser.dateURL(current.absoluteString, orderID: orderID) != nil else { throw MallWebError.identityMismatch }
                            try await validateLiveAccount(view)
                            return snapshot
                        }
                    }
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            // An evidenced empty structured response is provisional until the normal
            // capture window ends: later numbered split-package data still takes precedence.
            try Task.checkCancellation()
            if let failed { throw failed }
            guard finished, let current = view.url, MallPlatform.jd.allowed(current) else { throw MallWebError.timeout }
            if let failure = MallWebParser.pageFailure(url: current, text: "") { throw failure }
            if let orderID {
                guard (dateOnly ? JDPageParser.dateURL(current.absoluteString, orderID: orderID) != nil : Shipment.logisticsEntry(current.absoluteString, orderID: orderID) != nil) else { throw MallWebError.identityMismatch }
            } else {
                guard current.host == "trade.m.jd.com", current.path == MallPlatform.jd.ordersURL.path else { throw MallWebError.identityMismatch }
            }
            guard (lastSnapshot?["pendingRequests"] as? Int ?? 0) == 0 else { throw MallWebError.timeout }
            try await validateLiveAccount(view)
            try Task.checkCancellation()
            if let captured {
                try JDPageParser.failure(captured)
                if orderID == nil, let lastSnapshot, lastSnapshot["kind"] as? String == "orders" {
                    return try JDPageParser.supplement(captured, snapshot: lastSnapshot)
                }
                return captured
            }
            if orderID == nil, let lastSnapshot, lastSnapshot["recognized"] as? Bool == true { return lastSnapshot }
            if finished, !dateOnly, let emptyCapture { return emptyCapture }
            if let operationDeadline, ProcessInfo.processInfo.systemUptime >= operationDeadline { throw MallWebError.timeout }
            throw finished ? MallWebError.unsupported : MallWebError.timeout
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.web?.stopLoading() }
        })
    }
    private func validateLiveAccount(_ view: WKWebView) async throws {
        let native = await view.configuration.websiteDataStore.httpCookieStore.allCookies()
        try Task.checkCancellation()
        let values = native.map { TaobaoTrialCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, secure: $0.isSecure, expires: $0.expiresDate, httpOnly: $0.isHTTPOnly) }.filter { MallSession.valid($0, platform: .jd) }
        // A mobile pt_pin session may not change accounts while a page is being read.
        if cookies.contains(where: { $0.name == "pt_pin" }) {
            guard JDPageParser.sameAccount(cookies, values) else { throw MallWebError.identityMismatch }
        }
    }
    private func cleanup() {
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "jdCapture")
        web?.configuration.userContentController.removeAllUserScripts()
        web?.removeFromSuperview()
        web = nil
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "jdCapture", message.frameInfo.isMainFrame,
              let origin = message.frameInfo.request.url, MallPlatform.jd.allowed(origin),
              let current = web?.url, MallPlatform.jd.allowed(current),
              let body = message.body as? [String: Any], JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 1_000_000 else {
            diagnostics.event(.jdBridgeRejected, reason: .envelope); return
        }
        if body["kind"] as? String == "diagnostic" {
            // Only exact labels and bounded counts from known page request classes.
            let code = body["diagnostic"] as? String
            if code == "networkResponse", let status = body["httpStatus"] as? Int, (100...599).contains(status) {
                diagnostics.event(.jdNetworkResponse, counts: [.httpStatus: status])
            } else if code == "schema" || code == "json" || code == "business" {
                diagnostics.event(.jdResponseRejected, reason: code == "business" ? .interface : .parse)
            } else if code == "network" {
                diagnostics.event(.jdResponseRejected, reason: .network)
            }
            return
        }
        if body["error"] != nil {
            diagnostics.event(.jdResponseRejected, reason: (body["error"] as? String) == "identity" ? .identity : ((body["error"] as? String) == "authentication" ? .authentication : .verification))
            do { try JDPageParser.failure(body) } catch { failed = error }
            return
        }
        if let expectedOrder {
            guard !dateOnly else { return }
            guard current.path == "/order/deal_wuliu_jdm.shtml",
                  Shipment.logisticsEntry(current.absoluteString, orderID: expectedOrder) != nil,
                  ["logistics", "logisticsEmpty"].contains(body["kind"] as? String ?? "") else {
                diagnostics.event(.jdBridgeRejected, reason: .identity); return
            }
        } else {
            guard current.path == MallPlatform.jd.ordersURL.path, body["kind"] as? String == "orders" else {
                diagnostics.event(.jdBridgeRejected, reason: .identity); return
            }
        }
        if body["kind"] as? String == "logisticsEmpty" {
            guard let expectedOrder, body["orderID"] as? String == expectedOrder,
                  body["recognized"] as? Bool == true,
                  let parcels = body["parcels"] as? [[String: Any]], parcels.isEmpty else {
                diagnostics.event(.jdBridgeRejected, reason: .identity); return
            }
            var empty = body; empty["kind"] = "logistics"
            emptyCapture = empty
            return
        }
        diagnostics.event(.jdBridgeAccepted, counts: [.bytes: data.count])
        do {
            if let expectedOrder {
                _ = try JDPageParser.parcels(body, orderID: expectedOrder)
            } else {
                _ = try JDPageParser.orders(body)
            }
            captured = body
        } catch { failed = error }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, MallPlatform.jd.allowed(url) else {
            diagnostics.event(.jdNavigationRejected, reason: .url); decisionHandler(.cancel); return
        }
        if navigationAction.targetFrame == nil {
            diagnostics.event(.jdNavigationRejected, reason: .frame); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url, MallPlatform.jd.allowed(url) else {
            diagnostics.event(.jdNavigationRejected, reason: .url); decisionHandler(.cancel); return
        }
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse {
            diagnostics.event(.jdNetworkResponse, counts: [.httpStatus: response.statusCode])
        }
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            failed = response.statusCode == 401 ? MallWebError.authentication : (response.statusCode == 403 || response.statusCode == 429 ? MallWebError.verification : MallWebError.unsupported)
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        finished = false; diagnostics.event(.jdNavigation)
    }
    private func navigationFailure(_ error: Error) -> Error {
        var counts: [DiagnosticMetric: Int] = [:]
        if let code = JDDiagnostics.safeNetworkCode(error) { counts[.errorCode] = code }
        diagnostics.event(.jdNavigationFailed, reason: JDDiagnostics.reason(error), counts: counts)
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return CancellationError() }
        return JDLoggedError(reason: failure.domain == NSURLErrorDomain && failure.code == NSURLErrorTimedOut ? .timeout : .network,
                             stage: diagnostics.trace.stage ?? .jdOrdersPage)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed = navigationFailure(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed = navigationFailure(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        diagnostics.event(.jdProcessTerminated, reason: .unavailable)
        failed = JDLoggedError(reason: .unavailable, stage: diagnostics.trace.stage ?? .jdOrdersPage)
    }
}

enum JDPageScript {
    static let capture = #"""
(() => {
'use strict';
if (window.__parcelJDSnapshot) return;
const MAX = 1000000;
const text = (v, n = 1000) => typeof v === 'string' ? v.slice(0, n) : (typeof v === 'number' && Number.isSafeInteger(v) ? String(v) : '');
const id = v => /^[0-9]{6,32}$/.test(text(v));
function allowed(raw) {
  try { const u = new URL(raw, location.href); return u.protocol === 'https:' && !u.username && !u.password && (!u.port || u.port === '443') && (u.hostname === 'jd.com' || u.hostname.endsWith('.jd.com')); } catch (_) { return false; }
}
function safeLink(raw, order) {
  try {
    const u = new URL(raw || '/order/deal_wuliu_jdm.shtml?dealId=' + order, 'https://trade.m.jd.com');
    if (!allowed(u.href) || u.hostname !== 'trade.m.jd.com' || u.pathname !== '/order/deal_wuliu_jdm.shtml' || u.hash || u.searchParams.getAll('dealId').length !== 1 || u.searchParams.get('dealId') !== order) return '';
    const out = new URL('https://trade.m.jd.com/order/deal_wuliu_jdm.shtml');
    for (const key of ['from','dealState','dealId','orderType','skuid','shopid','source']) {
      const values = u.searchParams.getAll(key); if (values.length > 1) return '';
      if (values.length) out.searchParams.set(key, values[0].slice(0,256));
    }
    return out.href;
  } catch (_) { return ''; }
}
function evidenceURL(raw, order) {
  try {
    const u = new URL(raw,location.href), keys=['orderId','orderid','dealId'];
    const values=keys.flatMap(key=>u.searchParams.getAll(key));
    if (!allowed(u.href) || u.hostname !== 'trade.m.jd.com' || !u.pathname.startsWith('/order/') || !/detail/i.test(u.pathname) || ['/order/deal_wuliu_jdm.shtml','/order/orderlist_jdm.shtml'].includes(u.pathname) || u.hash || values.length !== 1 || values[0] !== order || !id(order)) return '';
    if (u.href.length > 2048 || Array.from(u.searchParams.keys()).some(k=>/cookie|token|pt_|thor|password|pin/i.test(k))) return '';
    return u.href;
  } catch (_) { return ''; }
}
function nextLink() {
  const links=[];
  for (const a of document.querySelectorAll('a[href]')) {
    const label=(a.innerText || '').trim(), rel=a.getAttribute ? a.getAttribute('rel') : '';
    if (rel !== 'next' && !/^(?:下一页|下页)$/.test(label)) continue;
    try {
      const u=new URL(a.href,location.href);
      if (!allowed(u.href) || u.hostname !== 'trade.m.jd.com' || u.pathname !== '/order/orderlist_jdm.shtml' || u.hash || u.href === location.href || u.href.length > 2048 || Array.from(u.searchParams.keys()).some(k=>/cookie|token|pt_|thor|password|pin/i.test(k))) continue;
      if (!links.includes(u.href)) links.push(u.href);
    } catch (_) {}
  }
  return links.length === 1 ? links[0] : '';
}
function submission(value) {
  const rows=Array.from(value.matchAll(/(?:^|[\n\r])[ \t]*(?:下单时间|下单日期|提交订单时间|订单创建时间)[ \t]*[:：]?[ \t]*([0-9]{4}-[0-9]{2}-[0-9]{2}(?:[ T][0-9]{2}:[0-9]{2}(?::[0-9]{2})?)?)(?=[ \t]*(?:$|[\n\r]))/g),m=>m[1]);
  return rows.length === 1 ? rows[0] : '';
}
let pendingRequests=0;
function emit(value) { try { if (JSON.stringify(value).length <= MAX) window.webkit.messageHandlers.jdCapture.postMessage(value); } catch (_) {} }
function diagnostic(label, status) {
  if (!['schema','json','business','network','networkResponse'].includes(label)) return;
  const value = {kind:'diagnostic',diagnostic:label};
  if (Number.isInteger(status) && status >= 100 && status <= 599) value.httpStatus = status;
  emit(value);
}
function knownRequest(raw, body) {
  try {
    if (!allowed(raw)) return false;
    const u = new URL(raw,location.href);
    const fn = u.searchParams.get('functionId') || new URLSearchParams(typeof body === 'string' ? body : '').get('functionId');
    return ['order_list_m','get_logistics_list_by_order_m','pcorder_center_list','pcdetail_traceMultiPackage'].includes(fn);
  } catch (_) { return false; }
}
function requestOrder(raw, body) {
  try {
    const u = new URL(raw, location.href);
    const params = new URLSearchParams(typeof body === 'string' ? body : '');
    const object = JSON.parse(u.searchParams.get('body') || params.get('body') || '{}');
    const value = text(object.orderId || object.orderID || u.searchParams.get('orderId') || u.searchParams.get('dealId'));
    return id(value) ? value : '';
  } catch (_) { return ''; }
}
function points(rows, timeKey, textKey, statusKey = '') {
  if (!Array.isArray(rows) || rows.length > 300) return null;
  return rows.map(p => {
    const content = text(p[textKey],3000), status = statusKey ? text(p[statusKey],1000) : '';
    return {time: typeof p[timeKey] === 'number' ? p[timeKey] : text(p[timeKey],80), text:status && status !== content ? [status,content].filter(Boolean).join(' ') : content};
  });
}
// Accumulate only within this main-frame document and exact order. No DOM trace fallback.
const parcelSets = new Map();
function mergeParcels(orderID, parcels) {
  const previous = parcelSets.get(orderID) || [];
  const merged = previous.map(p => ({...p,points:p.points.slice()}));
  for (const parcel of parcels) {
    if (!Array.isArray(parcel.points)) return null;
    const old = merged.find(p => p.number === parcel.number);
    if (!old) { merged.push({...parcel,points:parcel.points.slice()}); continue; }
    if (old.carrier && parcel.carrier && old.carrier !== parcel.carrier) { emit({error:'identity'}); return null; }
    old.carrier = old.carrier || parcel.carrier;
    for (const point of parcel.points) if (!old.points.some(p => p.time === point.time && p.text === point.text)) old.points.push(point);
    if (old.points.length > 300) return null;
  }
  if (merged.length > 40) return null;
  parcelSets.set(orderID,merged);
  return merged;
}
function capture(raw, requestURL, requestBody, responseURL) {
  if (typeof raw !== 'string' || raw.length > MAX || !allowed(requestURL) || (responseURL && !allowed(responseURL))) return;
  try {
    const u = new URL(requestURL, location.href);
    const fn = u.searchParams.get('functionId') || new URLSearchParams(typeof requestBody === 'string' ? requestBody : '').get('functionId');
    if (!['order_list_m','get_logistics_list_by_order_m','pcorder_center_list','pcdetail_traceMultiPackage'].includes(fn)) return;
    const root = JSON.parse(raw);
    if (root.code === 3 || root.code === '3') { emit({error:'authentication'}); return; }
    if (root.code === 403 || root.code === '403' || root.code === 429 || root.code === '429') { emit({error:'verification'}); return; }
    if (root.code !== undefined && ![0,'0',200,'200'].includes(root.code)) { diagnostic('business'); return; }
    if (root.success === false) { diagnostic('business'); return; }
    const b = root.body || root.data || root;
    if (fn === 'order_list_m' || fn === 'pcorder_center_list') {
      if (!Array.isArray(b.orderList) || b.orderList.length > 200) { diagnostic('schema'); return; }
      const orders = b.orderList.map(o => {
        const status = o.orderStatusInfo || o.statusInfo || {};
        const goods = (o.wareInfoList || o.wareList || [])[0] || {};
        const order = text(o.orderId);
        const statusName = text(status.orderStatusName || status.orderStateName,1000);
        const allGoods = o.wareInfoList || o.wareList || [];
        const excluded = [4,69].includes(Number(o.orderType)) || (Array.isArray(allGoods) && allGoods.length > 0 && allGoods.every(w => Number(w.wareType) === 1)) || /外卖|秒送|虚拟订单|虚拟业务|虚拟服务|服务订单|生活服务/.test(statusName + ' ' + text(o.orderTypeName));
        // Only dateSubmit is evidenced as an order submission field. Do not guess
        // createTime/orderTime/deliveryTime or use an event's date to qualify an order.
        return {id:order, title:text(goods.wareName || goods.name,200), status:statusName, excluded, submittedAt:text(o.dateSubmit,80), url:safeLink(o.progressInfo && o.progressInfo.progressLink,order)};
      });
      emit({kind:'orders',recognized:true,orders}); return;
    }
    const requestID = requestOrder(requestURL,requestBody);
    const returnedID = text(b.orderId || b.orderID || root.orderId);
    if (returnedID && requestID && returnedID !== requestID) { emit({error:'identity'}); return; }
    const orderID = returnedID || requestID;
    if (!id(orderID)) return;
    let parcels;
    if (Array.isArray(b.multiPackageTrackInfoList) && b.multiPackageTrackInfoList.length <= 40) {
      parcels = b.multiPackageTrackInfoList.map(p => {
        const g = p.trackGroupInfo || {}, top = p.carriageInfo || {}, nested = g.orderCarriageInfo || {};
        const a = text(top.carriageId,40), b = text(nested.carriageId,40);
        if (a && b && a !== b) return {conflict:true};
        const number = a || b, carrier = text(top.carrier,100) || text(nested.carrier,100);
        return {number,carrier,points:points(g.orderTrackShowList,'CreationTime','Content','StatusName')};
      });
      if (parcels.some(p => p.conflict)) { emit({error:'identity'}); return; }
    } else if (Object.prototype.hasOwnProperty.call(b,'carriageId') && Array.isArray(b.tracePointVOList)) {
      parcels = [{number:text(b.carriageId,40),carrier:text(b.carrier,100),points:points(b.tracePointVOList,'createTime','wlStateDesc')}];
    } else { diagnostic('schema'); return; }
    // Provisional structured empty evidence, not an immediate successful capture.
    // Native waits for subsequent numbered responses before counting withoutWaybill.
    parcels = parcels.filter(p => p.number !== '');
    if (!parcels.length) { emit({kind:'logisticsEmpty',recognized:true,orderID,parcels:[]}); return; }
    const merged = mergeParcels(orderID,parcels);
    if (!merged) { diagnostic('schema'); return; }
    emit({kind:'logistics',recognized:true,orderID,parcels:merged});
  } catch (_) { diagnostic('json'); }
}
const originalFetch = window.fetch;
if (typeof originalFetch === 'function') window.fetch = function(input, init) {
  const url = typeof input === 'string' ? input : (input && input.url);
  const body = init && init.body;
  const known=knownRequest(url,body);
  const promise = originalFetch.apply(this, arguments);
  if (known) pendingRequests++;
  promise.then(response => {
    try {
      if (knownRequest(url,body)) diagnostic('networkResponse',response.status);
      response.clone().text().then(raw => capture(raw,url,body,response.url)).catch(()=>{if(known) diagnostic('network');}).finally(()=>{if(known) pendingRequests--;});
    } catch (_) { if(known) { diagnostic('network'); pendingRequests--; } }
  },()=>{if(known) { diagnostic('network'); pendingRequests--; }});
  return promise;
};
if (window.XMLHttpRequest) {
  const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
  const metadata = new WeakMap();
  XMLHttpRequest.prototype.open = function(method,url) { metadata.set(this,{url}); return open.apply(this,arguments); };
  XMLHttpRequest.prototype.send = function(body) {
    const data = metadata.get(this), known=data && knownRequest(data.url,body);
    if (known) {
      pendingRequests++;
      let ended=false;
      const complete=()=>{if (!ended) {ended=true;pendingRequests--;}};
      for (const event of ['loadend','error','timeout','abort']) this.addEventListener(event,complete);
    }
    this.addEventListener('load',()=>{try {
      if (data && knownRequest(data.url,body)) diagnostic('networkResponse',this.status);
      if (data) capture(this.responseText,data.url,body,this.responseURL);
    } catch (_) {if(data && knownRequest(data.url,body)) diagnostic('network');}});
    this.addEventListener('error',()=>{if(data && knownRequest(data.url,body)) diagnostic('network');});
    this.addEventListener('timeout',()=>{if(data && knownRequest(data.url,body)) diagnostic('network');});
    return send.apply(this,arguments);
  };
}
window.__parcelJDSnapshot = () => {
  const body = document.body ? (document.body.innerText || '').slice(0,200000) : '';
  if (/请完成安全验证|拖动滑块|请输入验证码|访问过于频繁/.test(body)) return {error:'verification'};
  const here = new URL(location.href);
  if (!allowed(here.href)) return {recognized:false};
  if (/login/i.test(here.pathname)) return {error:'authentication'};
  if (here.pathname === '/order/orderlist_jdm.shtml') {
    const orders = [], seen = new Set();
    for (const anchor of document.querySelectorAll('a[href]')) {
      let link; try { link = new URL(anchor.href,location.href); } catch (_) { continue; }
      const identities=['dealId','orderId','orderid'].flatMap(key=>link.searchParams.getAll(key));
      if (identities.length !== 1) continue;
      const order = identities[0];
      const detail=evidenceURL(link.href,order);
      const url = detail ? safeLink('',order) : safeLink(link.href,order);
      if (!id(order) || !url || seen.has(order)) continue;
      const card = anchor.closest('[data-order-id], [data-orderid], .order_item, .order-item, .order-list-item');
      if (!card) continue;
      const value = (card.innerText || '').slice(0,1000);
      const explicit = value.match(/订单(?:号|编号)\s*[:：]?\s*(\d{6,32})/);
      if (explicit && explicit[1] !== order) continue;
      const submitted = submission(value);
      const detailLinks=detail ? [detail] : [];
      for (const a of (card.querySelectorAll ? card.querySelectorAll('a[href]') : [])) {
        const candidate=evidenceURL(a.href,order); if (candidate && !detailLinks.includes(candidate)) detailLinks.push(candidate);
      }
      const dateURL=detailLinks.length === 1 ? detailLinks[0] : '';
      // Classify business labels/status lines, not arbitrary product-title text.
      const business = value.split(/[\n\r]/).filter(line => /^(?:京东外卖|京东秒送|外卖订单|秒送订单|虚拟订单|服务订单)(?:\s|$|[:：])/.test(line.trim())).join(' ');
      const state = value.split(/[\n\r]/).filter(line => /^(?:已完成|已签收|待收货|待发货|已取消|待付款|运输中|配送中|派送中)$/.test(line.trim())).join(' ');
      seen.add(order); orders.push({id:order,title:value.slice(0,200),status:state,excluded:/外卖|秒送|虚拟|服务订单/.test(business),submittedAt:submitted,url,dateURL});
      if (orders.length >= 200) break;
    }
    // A positive, page-local empty-state is different from an unknown page.
    const empty = /暂无订单|暂时没有订单|您还没有相关订单/.test(body);
    return {kind:'orders',recognized:orders.length > 0 || empty,orders,nextURL:nextLink(),pendingRequests};
  }
  const dateOrder=['orderId','orderid','dealId'].flatMap(key=>here.searchParams.getAll(key));
  if (dateOrder.length === 1 && evidenceURL(here.href,dateOrder[0])) {
    // Read only an explicit date label, never trace text. Page URL alone is not identity evidence.
    const ids=Array.from(body.matchAll(/(?:^|[\n\r])[ \t]*订单(?:号|编号)[ \t]*[:：]?[ \t]*(\d{6,32})(?=[ \t]*(?:$|[\n\r]))/g),m=>m[1]);
    const submittedAt=submission(body);
    if (ids.length === 1 && ids[0] === dateOrder[0] && submittedAt) return {kind:'orderDate',recognized:true,orderID:ids[0],submittedAt};
  }
  if (here.pathname === '/order/deal_wuliu_jdm.shtml') {
    const orderID = here.searchParams.get('dealId');
    if (!id(orderID) || !safeLink(here.href,orderID)) return {recognized:false};
    // No evidenced page-local logistics container is available. A page URL and
    // one waybill header do not prove that dated DOM text belongs to that parcel
    // (recommendations may contain later delivery events without any waybill).
    // Fail closed rather than invent CSS selectors or scan the whole page.
    // The authenticated structured response capture above remains enabled.
    return {recognized:false,pendingRequests};
  }
  return {recognized:false,pendingRequests};
};
})();
"""#
}
