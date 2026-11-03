import SwiftUI

struct KDYZMSettingsView: View {
    @EnvironmentObject private var store: ShipmentStore
    @State private var origin = ""
    @State private var code = ""
    @State private var preview: KDYZMPreview?
    @State private var previewOrigin = ""
    @State private var previewCode = ""
    @State private var credential: KDYZMCredential?
    @State private var accounts: [KDYZMAccount] = []
    @State private var families: [KDYZMFamily] = []
    @State private var busy = false
    @State private var message: String?
    @State private var confirmUnbind = false
    @State private var confirmLocal = false
    private let client = KDYZMClient()

    var body: some View {
        Form {
            if store.isHistoricalSnapshot {
                Text("当前为只读历史快照，不能绑定、解绑或同步。请先修复共享存储。")
                    .foregroundStyle(.orange)
            }
            if let credential {
                Section("已绑定") {
                    Text(credential.baseURL).textSelection(.enabled)
                    Text("设备：" + credential.deviceID).font(.caption)
                    ForEach(families) { family in Text("家人：" + family.name) }
                    ForEach(accounts) { account in
                        VStack(alignment: .leading) {
                            Text(account.label + " · " + account.platform)
                            Text([account.familyName, account.status].compactMap { $0 }.joined(separator: " · ")).font(.caption)
                        }
                    }
                    Button("读取授权账号") { run { try await readAccounts(credential) } }
                    Button("同步京东快照") {
                        run {
                            message = try await store.syncKDYZM().message
                            try await readAccounts(credential)
                        }
                    }
                    Text("展示全部授权账号；本版仅 syncJD：导入京东运单，不改变淘宝／拼多多现有功能。同步只 GET 快照，不请求全账号采集，不上传取件、隐藏或备注操作。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("撤销设备并解绑", role: .destructive) { confirmUnbind = true }
                    Button("仅本机解绑…", role: .destructive) { confirmLocal = true }
                }
            } else {
                Section("连接后台") {
                    TextField("https://后台地址:端口", text: $origin)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("一次性绑定码", text: $code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("预检授权范围") {
                        run {
                            preview = nil
                            let base = try KDYZMOrigin(origin).value
                            let result = try await client.preview(origin: base, code: code)
                            previewOrigin = base; previewCode = code; preview = result
                        }
                    }
                    Text("仅需 HTTPS 地址和一次性绑定码，不需要管理员密码、京东 Cookie 或 UAPI。自签证书不会被自动信任，内网地址需有效且受系统信任的证书。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let preview {
                    Section("确认授权（预检不消耗绑定码）") {
                        Text(preview.service.name)
                        Text(previewOrigin)
                        ForEach(preview.scope.families) { f in Text("家人：\(f.name)（\(f.accountCount ?? 0) 个账号）") }
                        ForEach(preview.scope.accounts) { a in Text(a.label + " · " + a.platform) }
                        Text(preview.scope.includeFutureAccounts ? "持续授权上述家人组，包括以后加入的账号。" : "仅授权明确列出的账号。")
                        Text("绑定码有效至 " + expiryText(preview.expiresAt))
                        Button("确认授权并绑定") {
                            run {
                                guard origin == previewOrigin || (try? KDYZMOrigin(origin).value) == previewOrigin,
                                      code == previewCode else { self.preview = nil; throw KDYZMError.stale }
                                try await KDYZMConnection.shared.bind(origin: previewOrigin, code: previewCode, preview: preview, deviceName: "快递管家 iOS")
                                code = ""; previewCode = ""; self.preview = nil
                                credential = try await KDYZMConnection.shared.current()
                                if let credential { try await readAccounts(credential) }
                                message = "设备已绑定，尚未同步；点击同步京东快照导入。"
                            }
                        }
                    }
                }
            }
            if busy { ProgressView("正在请求后台并等待结果；不会保证任务自动完成。") }
            if let message { Section("结果") { Text(message).textSelection(.enabled) } }
        }
        .navigationTitle("取件助手后台")
        .disabled(busy || store.isHistoricalSnapshot)
        .task {
            do {
                credential = try await KDYZMConnection.shared.current()
                if let credential { origin = credential.baseURL }
            } catch { message = KDYZMError.safe(error) }
        }
        .onDisappear { code = ""; previewCode = ""; preview = nil }
        .confirmationDialog("撤销后台设备授权并解绑？本地运单保留。", isPresented: $confirmUnbind, titleVisibility: .visible) {
            Button("撤销并解绑", role: .destructive) {
                run {
                    try await KDYZMConnection.shared.unbind()
                    credential = nil; accounts = []; families = []
                    message = "后台撤权已读回确认，本机凭据已清除；本地运单保留。"
                }
            }
        }
        .confirmationDialog("仅清除本机凭据，不撤销后台设备！请稍后由管理员撤销遗留设备。", isPresented: $confirmLocal, titleVisibility: .visible) {
            Button("确认仅本机解绑", role: .destructive) {
                run {
                    try await KDYZMConnection.shared.unbind(localOnly: true)
                    credential = nil; accounts = []; families = []
                    message = "仅本机凭据已清除；后台设备仍可能有效，需管理员撤销。"
                }
            }
        }
    }
    private func expiryText(_ milliseconds: Double) -> String {
        do {
            guard let date = try KDYZMTime.date(milliseconds) else { return "未知" }
            return ShipmentDateDisplay.string(date)
        } catch { return "未知" }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !store.isHistoricalSnapshot else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() }
            catch { message = KDYZMError.safe(error) }
        }
    }
    @MainActor private func readAccounts(_ expected: KDYZMCredential) async throws {
        struct Response: Decodable { var accounts: [KDYZMAccount]; var families: [KDYZMFamily]? }
        let response = try await client.request(Response.self, origin: expected.baseURL, path: "/v1/accounts", credential: expected)
        try await KDYZMConnection.shared.verify(expected)
        guard Set(response.accounts.map(\.id)).count == response.accounts.count,
              Set((response.families ?? []).map(\.id)).count == (response.families ?? []).count else { throw KDYZMError.invalid }
        accounts = response.accounts; families = response.families ?? []
    }
}
