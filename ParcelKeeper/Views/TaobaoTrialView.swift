import SwiftUI
import WebKit

@MainActor
final class TaobaoTrialBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    let web: WKWebView
    @Published var message = "仅在淘宝HTTPS网页内登录；验证码请手动完成。"
    init(cookies: [TaobaoTrialCookie]) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        web.navigationDelegate = self
        // No JS credential bridge and no shared/system cookie storage.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for cookie in cookies where cookie.expires.map({ $0 > Date() }) ?? true {
                guard let origin = URL(string: "https://" + cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))),
                      TaobaoTrialPolicy.allowed(origin) else { continue }
                var properties: [HTTPCookiePropertyKey: Any] = [.name: cookie.name, .value: cookie.value,
                    .domain: cookie.domain, .path: cookie.path, .secure: cookie.secure ? "TRUE" : "FALSE"]
                if let expires = cookie.expires { properties[.expires] = expires }
                if let item = HTTPCookie(properties: properties) { await web.configuration.websiteDataStore.httpCookieStore.setCookie(item) }
            }
            web.load(URLRequest(url: URL(string: "https://login.m.taobao.com/login.htm?redirectURL=https%3A%2F%2Fmain.m.taobao.com%2F")!))
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, TaobaoTrialPolicy.allowed(url) else {
            message = "已阻止非淘宝HTTPS跳转。若验证依赖其他域名，本试验暂不支持；不绕过验证。"
            decisionHandler(.cancel); return
        }
        // Keep target=_blank in the same restricted WebView.
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request); decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url, TaobaoTrialPolicy.allowed(url) else {
            message = "已阻止不受支持的登录页面。"
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func capture() async throws -> [TaobaoTrialCookie] {
        guard let url = web.url, TaobaoTrialPolicy.allowed(url) else { throw TaobaoTrialError.login }
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
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
    func stop() { web.stopLoading() }
}
private struct TaobaoTrialWeb: UIViewRepresentable {
    let browser: TaobaoTrialBrowser
    func makeUIView(context: Context) -> WKWebView { browser.web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) { uiView.stopLoading() }
}
private struct TaobaoTrialLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser: TaobaoTrialBrowser
    @State private var saving = false
    let saved: () -> Void
    init(cookies: [TaobaoTrialCookie], saved: @escaping () -> Void) {
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
                                let cookies = try await browser.capture()
                                try TaobaoTrialSession().save(cookies)
                                browser.stop(); saved(); dismiss()
                            } catch { browser.message = "未保存会话：" + error.localizedDescription }
                        }
                    }.disabled(saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
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
                Button("登录／重新登录淘宝") { consent = true }.disabled(busy)
                Button("退出并清除会话", role: .destructive) {
                    task?.cancel(); operationID = nil; busy = false; report = nil; selected = []; cookies = []
                    do { try session.clear(); hasSession = false; message = "本机会话已清除。" }
                    catch { message = error.localizedDescription }
                }.disabled(busy)
            }
            Section("手动同步") {
                Button(busy ? "正在读取" : "读取待收货单号（不调用UAPI）") { fetch() }
                    .disabled(busy || !hasSession)
                Text("导入初始状态沿用现有“运输中”，仅作占位，不代表已核实物流；之后可手动查询UAPI。")
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
                                if store.contains(trackingNumber: candidate.number) { Text("已存在，将跳过，不覆盖").font(.caption) }
                            }
                        }
                    }
                    Button("确认导入选中的单号") { importSelected(report) }
                        .disabled(busy || selected.isEmpty || store.isHistoricalSnapshot)
                }
            }
            if let message { Section("结果") { Text(message).font(.footnote) } }
        }
        .navigationTitle("淘宝导入（试验）")
        .onAppear {
            do { cookies = try session.load(); hasSession = !cookies.isEmpty }
            catch TaobaoTrialError.login { hasSession = false }
            catch { message = error.localizedDescription }
        }
        .onDisappear { task?.cancel(); operationID = nil; busy = false }
        .confirmationDialog("允许在淘宝网页登录并保存本机会话？", isPresented: $consent, titleVisibility: .visible) {
            Button("同意并打开淘宝") { login = true }
            Button("取消", role: .cancel) {}
        } message: { Text("本功能不是官方开放平台授权。凭据只存本机，可能触发重新登录或验证，不保证可用；不要向聊天发送密码或Cookie。") }
        .sheet(isPresented: $login) {
            TaobaoTrialLoginView(cookies: cookies) {
                report = nil; selected = []
                do { cookies = try session.load(); hasSession = true; message = "会话已保存，请手动读取订单验证。" }
                catch { message = error.localizedDescription }
            }
        }
    }
    private func fetch() {
        report = nil; selected = []; message = nil
        let id = UUID(); operationID = id; busy = true
        task = Task { @MainActor in
            defer { if operationID == id { busy = false; operationID = nil } }
            do {
                let client = TaobaoTrialClient(cookies: try session.load())
                let value = try await client.fetch()
                try Task.checkCancellation()
                guard operationID == id else { return }
                report = value
                message = value.candidates.isEmpty ? "本页未取得可导入单号；不代表账号没有其他快递。" : "请核对并勾选后确认导入。"
            } catch is CancellationError { }
            catch { if operationID == id { message = error.localizedDescription } }
        }
    }
    private func importSelected(_ report: TaobaoTrialReport) {
        guard !store.isHistoricalSnapshot else { message = "只读历史数据，不能导入。"; return }
        var added = 0, skipped = 0, failed = 0
        for candidate in report.candidates where selected.contains(candidate.id) {
            let detection = CarrierDetector.detect(candidate.number, context: candidate.carrier)
            do {
                let shipment = Shipment(trackingNumber: candidate.number, carrierName: detection.carrier.name,
                    carrierCode: detection.carrier.code, note: candidate.title)
                try store.addThrowing(shipment); added += 1
            } catch ShipmentStore.ShipmentWriteError.duplicateTrackingNumber { skipped += 1 }
            catch { failed += 1 }
        }
        message = "新增\(added)票，已存在跳过\(skipped)票，失败\(failed)票。原有记录未覆盖，未调用UAPI。"
        selected = []
    }
}
