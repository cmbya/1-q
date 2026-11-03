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
        do { _ = try await orders(diagnostics: diagnostics); diagnostics.finish() }
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
        do {
            let report = try await collectOrders(diagnostics: diagnostics)
            report.logSummary(diagnostics)
            diagnostics.finish(); return report
        } catch { diagnostics.fail(error); throw error }
    }
    private func collectOrders(diagnostics: JDDiagnostics) async throws -> JDOrderImportReport {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        let policy = JDOrderImportPolicy(now: now())
        let list = try await orders(deadline: deadline, diagnostics: diagnostics)
        var report = JDOrderImportReport()
        // Only the page's own observed response/DOM is evidenced. No invented
        // mobile pagination parameters, signed endpoints, scroll selectors or total claims.
        report.limited = true
        let eligible = list.filter { report.consider(submittedAt: $0.submittedAt, excluded: $0.excluded, policy: policy) }
        for (index, order) in eligible.enumerated() {
            try Task.checkCancellation()
            guard index < JDOrderImportPolicy.maxDetails,
                  ProcessInfo.processInfo.systemUptime < deadline else { report.limited = true; break }
            let page: [String: Any]
            do {
                page = try await JDPageBrowser(cookies: cookies, diagnostics: diagnostics, browserStore: browserStore).read(url: order.url, orderID: order.id, operationDeadline: deadline)
            } catch {
                try Task.checkCancellation()
                guard JDOrderImportPolicy.isTimeout(error) else { throw error }
                report.limited = true; break
            }
            diagnostics.begin(.jdLogisticsParse)
            let parcels = try JDPageParser.parcels(page, orderID: order.id)
            diagnostics.event(.jdResponseAccepted, counts: [.rows: parcels.count])
            try report.append(parcels, orderID: order.id, title: order.title, url: order.url.absoluteString)
        }
        return report
    }

    func query(orderID: String, trackingNumber: String) async throws -> UAPITrackingResult {
        if browserStore == nil && MallSession.hasJDPCSession(cookies) { return try await JDPCClient(cookies: cookies, diagnosticLog: diagnosticLog).query(orderID: orderID, trackingNumber: trackingNumber) }
        let diagnostics = JDDiagnostics(.jdQuery, log: diagnosticLog)
        do {
            let value = try await queryResult(orderID: orderID, trackingNumber: trackingNumber, diagnostics: diagnostics)
            diagnostics.finish(); return value
        } catch { diagnostics.fail(error); throw error }
    }
    private func queryResult(orderID: String, trackingNumber: String, diagnostics: JDDiagnostics) async throws -> UAPITrackingResult {
        guard Shipment.validPlatformOrderID(orderID, platform: "jd"), MallWebParser.waybill(trackingNumber) else { throw MallWebError.identityMismatch }
        // Re-read the actual list to bind the detail link to this account's order.
        // Never trust a stored URL, substitute an order ID for a missing waybill,
        // or attach a whole split-order timeline to every parcel.
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        let matches = try await orders(deadline: deadline, diagnostics: diagnostics).filter { $0.id == orderID }
        guard matches.count == 1, let order = matches.first else { throw MallWebError.identityMismatch }
        let page = try await JDPageBrowser(cookies: cookies, diagnostics: diagnostics, browserStore: browserStore).read(url: order.url, orderID: orderID, operationDeadline: deadline)
        diagnostics.begin(.jdLogisticsParse)
        let parcels = try JDPageParser.parcels(page, orderID: orderID).filter { $0.number == trackingNumber }
        guard parcels.count == 1, let parcel = parcels.first else { throw MallWebError.identityMismatch }
        return try parcel.result(expected: trackingNumber, platform: .jd)
    }

    private func orders(deadline: TimeInterval? = nil, diagnostics: JDDiagnostics) async throws -> [JDPageParser.Order] {
        try Task.checkCancellation()
        let page = try await JDPageBrowser(cookies: cookies, diagnostics: diagnostics, browserStore: browserStore).read(url: MallPlatform.jd.ordersURL, orderID: nil, operationDeadline: deadline)
        diagnostics.begin(.jdOrdersParse)
        let values = try JDPageParser.orders(page)
        diagnostics.event(.jdResponseAccepted, counts: [.rows: values.count])
        return values
    }
}

enum JDPageParser {
    struct Order {
        let id: String
        let title: String
        let status: String
        let url: URL
        let submittedAt: Date?
        let excluded: Bool
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
                submittedAt: JDOrderImportPolicy.submittedDate(row["submittedAt"]), excluded: excluded))
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
    private var loggedDOM = false
    private let diagnostics: JDDiagnostics
    private let browserStore: WKWebsiteDataStore?
    init(cookies: [TaobaoTrialCookie], diagnostics: JDDiagnostics, browserStore: WKWebsiteDataStore? = nil) {
        self.cookies = cookies; self.diagnostics = diagnostics; self.browserStore = browserStore
    }

    func read(url: URL, orderID: String?, operationDeadline: TimeInterval? = nil) async throws -> [String: Any] {
        diagnostics.begin(.credential)
        try Task.checkCancellation()
        guard MallPlatform.jd.allowed(url), cookies.allSatisfy({ MallSession.valid($0, platform: .jd) }),
              MallSession.hasLoginCredentials(cookies, platform: .jd) else { throw MallWebError.authentication }
        // WebKit page execution is an app-foreground capability, not a background API.
        guard UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { throw MallWebError.unsupported }
        expectedOrder = orderID
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
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                if let failed { throw failed }
                if let captured { return captured }
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
                        if snapshot["recognized"] as? Bool == true { return snapshot }
                    }
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            // An evidenced empty structured response is provisional until the normal
            // capture window ends: later numbered split-package data still takes precedence.
            try Task.checkCancellation()
            if finished, let emptyCapture { return emptyCapture }
            if let operationDeadline, ProcessInfo.processInfo.systemUptime >= operationDeadline { throw MallWebError.timeout }
            throw finished ? MallWebError.unsupported : MallWebError.timeout
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.web?.stopLoading() }
        })
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
            captured = body; return
        }
        if let expectedOrder {
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
        captured = body
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
function points(rows, timeKey, textKey) {
  if (!Array.isArray(rows) || rows.length > 300) return null;
  return rows.map(p => ({time: typeof p[timeKey] === 'number' ? p[timeKey] : text(p[timeKey],80), text:text(p[textKey],4000)}));
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
        const excluded = [4,69].includes(Number(o.orderType)) || (Array.isArray(allGoods) && allGoods.length > 0 && allGoods.every(w => Number(w.wareType) === 1)) || /外卖|秒送|虚拟|服务/.test(statusName + ' ' + text(o.orderTypeName));
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
        const g = p.trackGroupInfo || {}, c = p.carriageInfo || g.orderCarriageInfo || {};
        return {number:text(c.carriageId,40),carrier:text(c.carrier,100),points:points(g.orderTrackShowList,'CreationTime','Content')};
      }).filter(p => p.number !== '');
    } else if (Object.prototype.hasOwnProperty.call(b,'carriageId') && Array.isArray(b.tracePointVOList)) {
      parcels = [{number:text(b.carriageId,40),carrier:text(b.carrier,100),points:points(b.tracePointVOList,'createTime','wlStateDesc')}];
    } else { diagnostic('schema'); return; }
    // Provisional structured empty evidence, not an immediate successful capture.
    // Native waits for subsequent numbered responses before counting withoutWaybill.
    parcels = parcels.filter(p => p.number !== '');
    if (!parcels.length) { emit({kind:'logisticsEmpty',recognized:true,orderID,parcels:[]}); return; }
    emit({kind:'logistics',recognized:true,orderID,parcels});
  } catch (_) { diagnostic('json'); }
}
const originalFetch = window.fetch;
if (typeof originalFetch === 'function') window.fetch = function(input, init) {
  const url = typeof input === 'string' ? input : (input && input.url);
  const body = init && init.body;
  const promise = originalFetch.apply(this, arguments);
  promise.then(response => {
    try {
      if (knownRequest(url,body)) diagnostic('networkResponse',response.status);
      response.clone().text().then(raw => capture(raw,url,body,response.url)).catch(()=>{if(knownRequest(url,body)) diagnostic('network');});
    } catch (_) { if(knownRequest(url,body)) diagnostic('network'); }
  },()=>{if(knownRequest(url,body)) diagnostic('network');});
  return promise;
};
if (window.XMLHttpRequest) {
  const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
  const metadata = new WeakMap();
  XMLHttpRequest.prototype.open = function(method,url) { metadata.set(this,{url}); return open.apply(this,arguments); };
  XMLHttpRequest.prototype.send = function(body) {
    const data = metadata.get(this);
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
      const order = link.searchParams.get('dealId');
      const url = safeLink(link.href,order);
      if (!id(order) || !url || seen.has(order)) continue;
      const card = anchor.closest('[data-order-id], [data-orderid], .order_item, .order-item, .order-list-item');
      if (!card) continue;
      const value = (card.innerText || '').slice(0,1000);
      const explicit = value.match(/订单(?:号|编号)\s*[:：]?\s*(\d{6,32})/);
      if (explicit && explicit[1] !== order) continue;
      const submitted = value.match(/(?:^|[\n\r])[ \t]*(?:下单时间|下单日期|提交订单时间|订单创建时间)[ \t]*[:：]?[ \t]*([0-9]{4}-[0-9]{2}-[0-9]{2}(?:[ T][0-9]{2}:[0-9]{2}(?::[0-9]{2})?)?)(?=[ \t]*(?:$|[\n\r]))/);
      // Classify business labels/status lines, not arbitrary product-title text.
      const business = value.split(/[\n\r]/).filter(line => /^(?:京东外卖|京东秒送|外卖订单|秒送订单|虚拟订单|服务订单)(?:\s|$|[:：])/.test(line.trim())).join(' ');
      const state = value.split(/[\n\r]/).filter(line => /^(?:已完成|已签收|待收货|待发货|已取消|待付款|运输中|配送中|派送中)$/.test(line.trim())).join(' ');
      seen.add(order); orders.push({id:order,title:value.slice(0,200),status:state,excluded:/外卖|秒送|虚拟|服务/.test(business),submittedAt:submitted ? submitted[1] : '',url});
      if (orders.length >= 200) break;
    }
    // A positive, page-local empty-state is different from an unknown page.
    const empty = /暂无订单|暂时没有订单|您还没有相关订单/.test(body);
    return {kind:'orders',recognized:orders.length > 0 || empty,orders};
  }
  if (here.pathname === '/order/deal_wuliu_jdm.shtml') {
    const orderID = here.searchParams.get('dealId');
    if (!id(orderID) || !safeLink(here.href,orderID)) return {recognized:false};
    // No evidenced page-local logistics container is available. A page URL and
    // one waybill header do not prove that dated DOM text belongs to that parcel
    // (recommendations may contain later delivery events without any waybill).
    // Fail closed rather than invent CSS selectors or scan the whole page.
    // The authenticated structured response capture above remains enabled.
    return {recognized:false};
  }
  return {recognized:false};
};
})();
"""#
}
