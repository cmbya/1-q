import SwiftUI
import WebKit

struct MallImportSummary {
    var added = 0
    var bound = 0
    var importFailed = 0
    var refreshed = 0
    var refreshFailed = 0
    var skipped = 0
    var message: String {
        "导入：新增\(added)票，已有记录补关联\(bound)票，失败\(importFailed)票。\n物流：更新\(refreshed)票，失败\(refreshFailed)票，未请求\(skipped)票。未调用UAPI。"
    }
}

/// Dedicated ephemeral browser; no JS credential bridge, system cookies or credential logging.
@MainActor
private final class MallLoginBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    let platform: MallPlatform
    @Published private(set) var web: WKWebView?
    @Published var message = "请在平台HTTPS网页中手动登录、完成验证；保存仅代表候选会话，不证明登录成功。"
    private var setup: Task<Void, Never>?
    private(set) var active = true

    init(platform: MallPlatform, cookies: [TaobaoTrialCookie]) {
        self.platform = platform
        let config = WKWebViewConfiguration()
        config.websiteDataStore = MallBrowserContext.store(for: platform)
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = platform.userAgent
        web = view
        super.init()
        view.navigationDelegate = self
        setup = Task { @MainActor [weak self] in
            guard let self else { return }
            let existing = await config.websiteDataStore.httpCookieStore.allCookies()
            for cookie in cookies {
                guard self.active, !Task.isCancelled else { return }
                if existing.contains(where: { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }) { continue }
                guard cookie.expires.map({ $0 > Date() }) ?? true,
                      let url = URL(string: "https://" + cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))),
                      platform.allowed(url) else { continue }
                var properties: [HTTPCookiePropertyKey: Any] = [.name: cookie.name, .value: cookie.value,
                    .domain: cookie.domain, .path: cookie.path, .secure: cookie.secure ? "TRUE" : "FALSE"]
                if let expires = cookie.expires { properties[.expires] = expires }
                if let value = HTTPCookie(properties: properties) {
                    await view.configuration.websiteDataStore.httpCookieStore.setCookie(value)
                }
            }
            guard self.active, !Task.isCancelled, platform.allowed(platform.loginURL) else { return }
            let current = await config.websiteDataStore.httpCookieStore.allCookies()
            let values = current.map { TaobaoTrialCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, secure: $0.isSecure, expires: $0.expiresDate) }
            guard self.active, !Task.isCancelled else { return }
            view.load(URLRequest(url: MallSession.hasLoginCredentials(values, platform: platform) ? platform.ordersURL : platform.loginURL))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard active, let url = navigationAction.request.url, platform.allowed(url) else {
            message = "已阻止平台许可范围之外的跳转；不打开外部App，不绕过验证。"
            decisionHandler(.cancel); return
        }
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard active, let url = navigationResponse.response.url, platform.allowed(url) else {
            message = "已阻止平台许可范围之外的页面响应。"
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func capture() async throws -> [TaobaoTrialCookie] {
        guard active, let web, let url = web.url, platform.allowed(url) else { throw CancellationError() }
        let values = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        try Task.checkCancellation()
        guard active else { throw CancellationError() }
        return values.compactMap { cookie in
            guard let origin = URL(string: "https://" + cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))),
                  platform.allowed(origin), cookie.expiresDate.map({ $0 > Date() }) ?? true else { return nil }
            return TaobaoTrialCookie(name: cookie.name, value: cookie.value, domain: cookie.domain,
                                     path: cookie.path, secure: cookie.isSecure, expires: cookie.expiresDate)
        }
    }

    func destroy() {
        active = false
        setup?.cancel(); setup = nil
        web?.stopLoading()
        web?.navigationDelegate = nil
        web = nil
    }
}

private struct MallLoginWeb: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) { uiView.stopLoading() }
}

private struct MallLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var browser: MallLoginBrowser
    let saved: () -> Void
    let readOnly: Bool
    @State private var saving = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack {
                Text(browser.message).font(.footnote).padding(.horizontal)
                if let web = browser.web { MallLoginWeb(web: web) }
            }
            .navigationTitle(browser.platform.title + "网页登录（试验）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { saveTask?.cancel(); browser.destroy(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "正在验证订单访问" : "验证并保存会话") {
                        saving = true
                        saveTask = Task { @MainActor in
                            defer { saving = false }
                            do {
                                let cookies = try await browser.capture()
                                guard browser.active, !Task.isCancelled, !readOnly else { return }
                                guard !cookies.isEmpty else {
                                    browser.message = "尚未读取到平台会话，请在网页完成登录后重试。"; return
                                }
                                guard MallSession.hasLoginCredentials(cookies, platform: browser.platform) else { throw MallWebError.authentication }
                                browser.message = "正在同平台网页环境验证订单访问；验证通过才保存。"
                                try await MallDirectClient(platform: browser.platform, cookies: cookies).verifySession()
                                let fresh = try await browser.capture()
                                guard browser.active, !Task.isCancelled, !readOnly else { return }
                                try MallSession(platform: browser.platform).save(fresh)
                                browser.destroy(); saved(); dismiss()
                            } catch is CancellationError { }
                            catch { browser.message = "会话未保存：" + ((error as? MallDirectError)?.localizedDescription ?? (error as? MallWebError)?.localizedDescription ?? "本机安全保存或订单验证失败。") }
                        }
                    }.disabled(saving || !browser.active || readOnly)
                }
            }
        }
        .onDisappear { saveTask?.cancel(); browser.destroy() }
    }
}

struct MallImportView: View {
    @EnvironmentObject private var store: ShipmentStore
    let platform: MallPlatform
    @State private var cookieImport = false
    @State private var cookieText = ""
    @State private var consent = false
    @State private var login = false
    @State private var browser: MallLoginBrowser?
    @State private var hasSession = false
    @State private var candidates: [MallCandidate] = []
    @State private var selected = Set<String>()
    @State private var message: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var operationID: UUID?
    private var session: MallSession { MallSession(platform: platform) }

    var body: some View {
        Form {
            Section(platform.title + "网页导入（试验）") {
                Text("在正常平台网页手动登录并读取自己的订单。非官方开放平台授权，网页改版、登录过期或风控可能导致不可用。不购买、不确认收货、不绕过验证。")
                    .font(.footnote)
                Text("会话仅保存在本机独立钥匙串，不进入JSON备份；退出会销毁登录网页并清除该平台会话，不影响其他平台。不要分享密码或Cookie。")
                    .font(.footnote)
                Text(hasSession ? "已保存候选会话（不代表登录有效）" : "尚未保存会话")
                Button("登录／重新登录" + platform.title) { consent = true }
                    .disabled(busy || store.isHistoricalSnapshot)
                Button("导入Cookie（备用）") { cookieText = ""; cookieImport = true }
                    .disabled(busy || store.isHistoricalSnapshot)
                Button("退出并清除本平台会话", role: .destructive) { clearSession() }
                    .disabled(store.isHistoricalSnapshot)
            }
            Section("手动读取与确认") {
                Button(busy ? "正在处理" : "读取网页订单（不调用UAPI）") { fetch() }
                    .disabled(busy || !hasSession || store.isHistoricalSnapshot)
                Text("仅展示本次网页能够读取的订单，非全量同步；缺少运单号不会用订单号替代。请核对预览并勾选，确认后才保存。已有票仅补平台关联，不覆盖备注／取件码。")
                    .font(.footnote)
                Text("确认后先导入／补关联，再按平台尝试刷新物流；整批物流请求预算20秒，登录／验证等错误会停止后续平台请求，但继续保存所选关联。未取得轨迹不代表已核实状态；不会自动调用UAPI。")
                    .font(.footnote)
            }
            if !candidates.isEmpty {
                Section("预览：\(candidates.count)票") {
                    ForEach(candidates) { candidate in
                        Toggle(isOn: Binding(get: { selected.contains(candidate.trackingNumber) }, set: { enabled in
                            if enabled { selected.insert(candidate.trackingNumber) } else { selected.remove(candidate.trackingNumber) }
                        })) {
                            VStack(alignment: .leading) {
                                Text(candidate.title).lineLimit(2)
                                Text(candidate.carrier + " · " + candidate.trackingNumber).font(.caption)
                                if store.contains(trackingNumber: candidate.trackingNumber) {
                                    Text("已存在：仅补关联，随后尝试更新平台物流").font(.caption)
                                }
                            }
                        }.disabled(busy || store.isHistoricalSnapshot)
                    }
                    Button("确认导入选中单号并尝试平台刷新") { importSelected() }
                        .disabled(busy || selected.isEmpty || store.isHistoricalSnapshot)
                }
            }
            if let message {
                Section("结果") { Text(message).font(.footnote).textSelection(.enabled) }
            }
            if store.isHistoricalSnapshot { Text("历史快照只读，不能登录、读取或导入。") }
        }
        .navigationTitle(platform.title + "导入（试验）")
        .onAppear { loadSession() }
        .onChange(of: platform) { _, _ in cancel(); browser?.destroy(); browser = nil; login = false; candidates = []; selected = []; message = nil; loadSession() }
        .onDisappear { cancel(); browser?.destroy(); browser = nil }
        .confirmationDialog("允许在" + platform.title + "网页登录并保存本机会话？", isPresented: $consent, titleVisibility: .visible) {
            Button("同意并打开平台网页") {
                guard !store.isHistoricalSnapshot else { return }
                browser?.destroy()
                // A missing/expired saved session must not prevent first-time login.
                browser = MallLoginBrowser(platform: platform, cookies: (try? session.load()) ?? [])
                login = true
            }
            Button("取消", role: .cancel) {}
        } message: { Text("平台将收到正常网页请求与登录信息，可能要求验证码或重新登录；保存候选Cookie不能证明登录成功，需手动读取订单验证。") }
        .sheet(isPresented: $cookieImport, onDismiss: { cookieText = "" }) {
            NavigationStack {
                Form {
                    Text("仅粘贴本平台Cookie值（name=value; name=value），不要粘贴curl或整组请求头。它等同登录凭据，不要发给他人。验证订单访问成功后才保存钥匙串；不进入JSON备份。")
                    SecureField("Cookie", text: $cookieText).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(busy ? "正在验证" : "验证并保存") { saveImportedCookie() }
                        .disabled(busy || cookieText.isEmpty || store.isHistoricalSnapshot)
                    if let message { Text(message).font(.footnote).textSelection(.enabled) }
                }
                .navigationTitle(platform.title + "Cookie导入")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { cancel(); cookieText = ""; cookieImport = false } } }
            }.interactiveDismissDisabled(busy)
        }
        .sheet(isPresented: $login, onDismiss: { browser?.destroy(); browser = nil }) {
            if let browser {
                MallLoginSheet(browser: browser, saved: {
                    candidates = []; selected = []; loadSession()
                    message = "已验证订单访问并保存本机会话；后续有效性仍以实际读取为准。"
                }, readOnly: store.isHistoricalSnapshot)
            }
        }
    }

    private func saveImportedCookie() {
        guard !busy, !store.isHistoricalSnapshot else { return }
        let parsed: [TaobaoTrialCookie]
        do { parsed = try MallCookieImport.parse(cookieText, platform: platform) }
        catch { cookieText = ""; message = "Cookie格式或必要登录凭据不完整，尚未保存。"; return }
        cookieText = ""; busy = true
        let id = UUID(); operationID = id
        task = Task { @MainActor in
            defer { if operationID == id { busy = false; task = nil; operationID = nil } }
            do {
                try await MallDirectClient(platform: platform, cookies: parsed).verifySession()
                try Task.checkCancellation()
                guard operationID == id, !store.isHistoricalSnapshot else { return }
                try session.save(parsed)
                await MallBrowserContext.clear(platform)
                guard operationID == id else { return }
                hasSession = true; cookieImport = false; candidates = []; selected = []
                message = "Cookie已通过订单访问验证并保存；未导入订单，未调用UAPI。"
            } catch is CancellationError { }
            catch { if operationID == id { message = "验证失败，原会话未替换：" + safeFailure(error) } }
        }
    }
    private func safeFailure(_ error: Error) -> String {
        if let direct = error as? MallDirectError { return direct.localizedDescription }
        return (error as? MallWebError)?.localizedDescription ?? "本机安全保存或读取失败。"
    }
    private func loadSession() {
        do { hasSession = !(try session.load()).isEmpty }
        catch { hasSession = false; message = "无法读取本机会话，请重新登录或清除会话。" }
    }

    private func cancel() {
        operationID = nil; task?.cancel(); task = nil; busy = false
    }

    private func clearSession() {
        guard !store.isHistoricalSnapshot else { return }
        cancel(); browser?.destroy(); browser = nil; login = false
        candidates = []; selected = []
        busy = true
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            do {
                try session.clear()
                await MallBrowserContext.clear(platform)
                hasSession = false; message = "本平台会话与网页上下文已清除，其他平台不受影响。"
            } catch { message = "清除失败，请重试；不能确认本机会话已删除。" }
        }
    }

    private func fetch() {
        guard !busy, !store.isHistoricalSnapshot else { return }
        candidates = []; selected = []; message = nil
        let id = UUID(); operationID = id; busy = true
        let currentPlatform = platform
        task = Task { @MainActor in
            defer { if operationID == id { busy = false; operationID = nil; task = nil } }
            do {
                let client = MallDirectClient(platform: currentPlatform, cookies: try session.load())
                let values = try await client.fetchOrders()
                try Task.checkCancellation()
                guard operationID == id, platform == currentPlatform, !store.isHistoricalSnapshot else { return }
                candidates = values
                message = values.isEmpty ? "本页未取得可导入运单，不代表账号没有其他快递。" : "请核对预览并勾选，尚未导入，也未调用UAPI。"
            } catch is CancellationError { }
            catch { if operationID == id { message = "读取订单失败：" + safeFailure(error) + " 未导入，未调用UAPI。" } }
        }
    }

    private func importSelected() {
        guard !busy, !store.isHistoricalSnapshot else { return }
        let values = candidates.filter { selected.contains($0.trackingNumber) }
        let id = UUID(); operationID = id; busy = true
        let currentPlatform = platform
        task = Task { @MainActor in
            defer { if operationID == id { busy = false; operationID = nil; task = nil } }
            var summary = MallImportSummary()
            var details: [String] = []
            var platformStopped = false
            let started = ProcessInfo.processInfo.systemUptime
            for candidate in values {
                guard !Task.isCancelled, operationID == id, platform == currentPlatform, !store.isHistoricalSnapshot else { return }
                let ticketID: UUID
                do {
                    let existed = store.contains(trackingNumber: candidate.trackingNumber)
                    ticketID = try store.importMall(candidate, platform: currentPlatform.rawValue)
                    if existed { summary.bound += 1 } else { summary.added += 1 }
                } catch {
                    summary.importFailed += 1
                    details.append(candidate.trackingNumber + "：导入／关联失败，未覆盖原记录。")
                    continue
                }
                let remaining = 20 - (ProcessInfo.processInfo.systemUptime - started)
                guard !platformStopped, remaining > 0 else {
                    summary.skipped += 1
                    details.append(candidate.trackingNumber + "：关联已保存，因验证或时间预算未请求物流。")
                    continue
                }
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
                    summary.refreshed += 1
                } catch {
                    deadline.cancel()
                    guard !Task.isCancelled, operationID == id else { return }
                    summary.refreshFailed += 1
                    // Never display raw web errors: responses may contain session material.
                    details.append(candidate.trackingNumber + "：关联已保存，物流未更新：" + safeFailure(error))
                    if let failure = error as? MallDirectError, failure.reason.stopsBatch { platformStopped = true }
                    if let failure = error as? MallWebError, failure.stopsBatch { platformStopped = true }
                }
            }
            guard !Task.isCancelled, operationID == id, platform == currentPlatform else { return }
            do { try store.reload() } catch { details.append("无法重新读取本地记录，请返回列表核对保存结果。") }
            message = ([summary.message] + details).joined(separator: "\n")
            selected = []
        }
    }
}
