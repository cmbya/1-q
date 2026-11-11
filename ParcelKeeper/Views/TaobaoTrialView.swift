// Legacy direct marketplace import is opt-in; source is retained for restoration.
#if ENABLE_DIRECT_MALL_IMPORT
import SwiftUI
import WebKit

@MainActor
final class TaobaoTrialBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    let web: WKWebView
    private var initializationTask: Task<Void, Never>?
    private var stopped = false
    @Published var message = "仅在淘宝HTTPS网页内登录；验证码请手动完成。"
    init(cookies: [TaobaoTrialCookie]) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        web.navigationDelegate = self
        // No JS credential bridge and no shared/system cookie storage.
        initializationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.initializationTask = nil }
            guard !self.stopped, !Task.isCancelled else { return }
            for cookie in cookies where cookie.expires.map({ $0 > Date() }) ?? true {
                guard !self.stopped, !Task.isCancelled else { return }
                guard let origin = URL(string: "https://" + cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))),
                      TaobaoTrialPolicy.allowed(origin) else { continue }
                var properties: [HTTPCookiePropertyKey: Any] = [.name: cookie.name, .value: cookie.value,
                    .domain: cookie.domain, .path: cookie.path, .secure: cookie.secure ? "TRUE" : "FALSE"]
                if let expires = cookie.expires { properties[.expires] = expires }
                if let item = HTTPCookie(properties: properties) { await self.web.configuration.websiteDataStore.httpCookieStore.setCookie(item) }
            }
            guard !self.stopped, !Task.isCancelled else { return }
            self.web.load(URLRequest(url: URL(string: "https://login.m.taobao.com/login.htm?redirectURL=https%3A%2F%2Fmain.m.taobao.com%2F")!))
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !stopped else { decisionHandler(.cancel); return }
        guard let url = navigationAction.request.url, TaobaoTrialPolicy.allowed(url) else {
            message = "已阻止跳转：\(navigationAction.request.url.map(TaobaoTrialPolicy.blockedDestination) ?? "未知地址")。若验证依赖其他域名，本试验暂不支持；不绕过验证。"
            decisionHandler(.cancel); return
        }
        // Keep target=_blank in the same restricted WebView.
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request); decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard !stopped else { decisionHandler(.cancel); return }
        guard let url = navigationResponse.response.url, TaobaoTrialPolicy.allowed(url) else {
            message = "已阻止登录页面：\(navigationResponse.response.url.map(TaobaoTrialPolicy.blockedDestination) ?? "未知地址")。"
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func capture() async throws -> [TaobaoTrialCookie] {
        guard !stopped, let url = web.url, TaobaoTrialPolicy.allowed(url) else { throw TaobaoTrialError.login }
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard !stopped, !Task.isCancelled else { throw CancellationError() }
        let result = cookies.compactMap { cookie -> TaobaoTrialCookie? in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard let origin = URL(string: "https://" + domain), TaobaoTrialPolicy.allowed(origin),
                  cookie.expiresDate.map({ $0 > Date() }) ?? true else { return nil }
            return TaobaoTrialCookie(name: cookie.name, value: cookie.value, domain: cookie.domain,
                path: cookie.path, secure: cookie.isSecure, expires: cookie.expiresDate)
        }
        // Presence is a candidate session only, never proof that order access works.
        guard result.contains(where: { ["cookie2", "_tb_token_", "unb"].contains($0.name) }) else { throw TaobaoTrialError.login }
        return result
    }
    func stop() {
        stopped = true
        initializationTask?.cancel()
        initializationTask = nil
        web.stopLoading()
    }
}
private struct TaobaoTrialWeb: UIViewRepresentable {
    let browser: TaobaoTrialBrowser
    func makeCoordinator() -> TaobaoTrialBrowser { browser }
    func makeUIView(context: Context) -> WKWebView { browser.web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: TaobaoTrialBrowser) { coordinator.stop() }
}
private struct TaobaoTrialLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser: TaobaoTrialBrowser
    @State private var saving = false
    let saved: () -> Void
    let readOnly: Bool
    init(cookies: [TaobaoTrialCookie], readOnly: Bool, saved: @escaping () -> Void) {
        self.readOnly = readOnly
        _browser = StateObject(wrappedValue: TaobaoTrialBrowser(cookies: cookies)); self.saved = saved
    }
    var body: some View {
        NavigationStack {
            VStack {
                Text(browser.message).font(.footnote).padding(.horizontal)
                TaobaoTrialWeb(browser: browser)
            }
            .navigationTitle("淘宝网页登录（试验）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { browser.stop(); dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存本机会话") {
                        saving = true
                        Task { @MainActor in
                            defer { saving = false }
                            do {
                                guard !readOnly, !Task.isCancelled else { return }
                                let cookies = try await browser.capture()
                                guard !readOnly, !Task.isCancelled else { return }
                                try TaobaoTrialSession().save(cookies)
                                browser.stop(); saved(); dismiss()
                            } catch { browser.message = "未保存会话：" + error.localizedDescription }
                        }
                    }.disabled(saving || readOnly)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .onDisappear { browser.stop() }
    }
}

struct TaobaoTrialView: View {
    @EnvironmentObject private var store: ShipmentStore
    @State private var consent = false
    @State private var login = false
    @State private var cookies: [TaobaoTrialCookie] = []
    @State private var hasSession = false
    @State private var report: TaobaoTrialReport?
    @State private var selected = Set<String>()
    @State private var message: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var operationID: UUID?
    private let session = TaobaoTrialSession()
    var body: some View {
        Form {
            Section("淘宝单平台试验") {
                Text("非官方客户端接口，可能受页面改版和风控影响。仅读取自己的待收货订单；不购买、不确认收货、不绕过验证码。仅预览单号，确认后才导入，不自动查询UAPI。")
                    .font(.footnote)
                Text("会话仅保存在本机钥匙串，不进入JSON备份；退出会清除会话。平台会收到网络请求及登录信息。")
                    .font(.footnote)
                Text(hasSession ? "本机会话已保存（不代表登录仍有效）" : "尚未保存会话")
                Button("登录／重新登录淘宝") { consent = true }.disabled(busy || store.isHistoricalSnapshot)
                Button("退出并清除会话", role: .destructive) {
                    guard !store.isHistoricalSnapshot else { return }
                    task?.cancel(); operationID = nil; busy = false; report = nil; selected = []; cookies = []
                    do { try session.clear(); hasSession = false; message = "本机会话已清除。" }
                    catch { message = error.localizedDescription }
                }.disabled(busy || store.isHistoricalSnapshot)
            }
            Section("手动同步") {
                Button(busy ? "正在读取" : "读取待收货单号（不调用UAPI）") { fetch() }
                    .disabled(busy || !hasSession || store.isHistoricalSnapshot)
                Text("确认后保存淘宝订单关联并尝试读取物流；无轨迹时默认“运输中”仍仅作占位，不代表已核实。后续按来源刷新，UAPI仅手动备用。")
                    .font(.footnote)
                Text("首版只读取第一页，最多处理8个待收货订单，可能遗漏其他订单；不是全量同步。缺少运单号不会用订单号替代。")
                    .font(.footnote)
            }
            if let report {
                Section("预览：\(report.candidates.count)票") {
                    Text("已检查\(report.scanned)个待收货订单，\(report.failed)个未返回运单。仅第一页，非全量。")
                        .font(.footnote)
                    ForEach(report.candidates) { candidate in
                        Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: { enabled in
                            if enabled { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
                        })) {
                            VStack(alignment: .leading) {
                                Text(candidate.title).lineLimit(2)
                                Text(candidate.carrier + " · " + candidate.number).font(.caption)
                                if store.contains(trackingNumber: candidate.number) { Text("已存在：确认后补淘宝关联，不覆盖备注／取件码；随后尝试更新淘宝物流").font(.caption) }
                            }
                        }
                    }
                    Button("确认导入选中的单号") { importSelected(report) }
                        .disabled(busy || selected.isEmpty || store.isHistoricalSnapshot)
                }
            }
            if let message {
                Section("结果") {
                    Text(message.components(separatedBy: "\n")[0]).font(.footnote)
                    DisclosureGroup("查看结果／错误详情") {
                        Text(message).font(.footnote).textSelection(.enabled)
                    }
                    ShareLink(item: message) { Label("分享诊断详情", systemImage: "square.and.arrow.up") }
                    Button("复制诊断详情") { UIPasteboard.general.string = message }
                }
            }
        }
        .navigationTitle("淘宝导入（试验）")
        .onAppear {
            do { cookies = try session.load(); hasSession = !cookies.isEmpty }
            catch TaobaoTrialError.login { hasSession = false }
            catch { message = error.localizedDescription }
        }
        .onDisappear { task?.cancel(); operationID = nil; busy = false }
        .confirmationDialog("允许在淘宝网页登录并保存本机会话？", isPresented: $consent, titleVisibility: .visible) {
            Button("同意并打开淘宝") { if !store.isHistoricalSnapshot { login = true } }
            Button("取消", role: .cancel) {}
        } message: { Text("本功能不是官方开放平台授权。凭据只存本机，可能触发重新登录或验证，不保证可用；不要向聊天发送密码或Cookie。") }
        .sheet(isPresented: $login) {
            TaobaoTrialLoginView(cookies: cookies, readOnly: store.isHistoricalSnapshot) {
                report = nil; selected = []
                do { cookies = try session.load(); hasSession = true; message = "会话已保存，请手动读取订单验证。" }
                catch { message = error.localizedDescription }
            }
        }
    }
    private func fetch() {
        guard !busy, !store.isHistoricalSnapshot else { return }
        report = nil; selected = []; message = nil
        let id = UUID(); operationID = id; busy = true
        task = Task { @MainActor in
            defer { if operationID == id { busy = false; operationID = nil } }
            do {
                let client = TaobaoTrialClient(cookies: try session.load())
                let value = try await client.fetch()
                try Task.checkCancellation()
                guard operationID == id, !store.isHistoricalSnapshot else { return }
                report = value
                message = value.candidates.isEmpty ? "本页未取得可导入单号；不代表账号没有其他快递。" : "请核对并勾选后确认导入。"
            } catch is CancellationError { }
            catch { if operationID == id { message = error.localizedDescription } }
        }
    }
    private func importSelected(_ report: TaobaoTrialReport) {
        guard !busy, !store.isHistoricalSnapshot else { return }
        let candidates = report.candidates.filter { selected.contains($0.id) }
        busy = true
        let id = UUID(); operationID = id
        task = Task { @MainActor in
            defer { if operationID == id { busy = false; operationID = nil; task = nil } }
            var added = 0, bound = 0, failed = 0, refreshed = 0
            var errors: [String] = []
            var platformStopped = false
            let started = ProcessInfo.processInfo.systemUptime
            for candidate in candidates {
                guard !Task.isCancelled, operationID == id, !store.isHistoricalSnapshot else { return }
                do {
                    let existed = store.contains(trackingNumber: candidate.number)
                    let ticketID = try store.importTaobao(candidate)
                    if existed { bound += 1 } else { added += 1 }
                    // Link/import first, then fetch actual trace without UAPI fallback.
                    let remaining = 20 - (ProcessInfo.processInfo.systemUptime - started)
                    if !platformStopped, remaining > 0 {
                        let request = Task { @MainActor in
                            try await TrackingRefreshService.live().refresh(id: ticketID, mode: .platformOnly)
                        }
                        let deadline = Task { @MainActor in
                            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)); request.cancel() }
                            catch { }
                        }
                        do {
                            _ = try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
                            deadline.cancel()
                            guard !Task.isCancelled, operationID == id else { return }
                            refreshed += 1
                        } catch {
                            deadline.cancel()
                            guard !Task.isCancelled, operationID == id else { return }
                            errors.append(candidate.number + "：" + error.localizedDescription)
                            if let failure = error as? TaobaoTrackingError, failure.stopsBatch { platformStopped = true }
                        }
                    } else { errors.append(candidate.number + "：已保存关联，因登录验证或时间限制未请求物流，请稍后刷新。") }
                } catch { failed += 1; errors.append(candidate.number + "：关联或保存失败，未覆盖原记录。") }
            }
            try? store.reload()
            guard !Task.isCancelled, operationID == id else { return }
            message = "新增\(added)票，已有记录关联\(bound)票，导入失败\(failed)票；淘宝物流更新\(refreshed)票。未调用UAPI。" + (errors.isEmpty ? "" : "\n" + errors.joined(separator: "\n"))
            selected = []
        }
    }
}
#endif
