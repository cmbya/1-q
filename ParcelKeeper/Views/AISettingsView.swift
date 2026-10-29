import SwiftUI

struct AISettingsView: View {
    private let service = AIService()
    @State private var config = AIConfiguration()
    @State private var saved = AIConfiguration()
    @State private var keyInput = ""
    @State private var keyStatus = "检查中…"
    @State private var busy = false
    @State private var message: String?
    @State private var showingConsent = false
    @State private var showingEndpointChange = false
    @State private var showingReuse = false
    @State private var reuseSource: String?
    @State private var networkTask: Task<Void, Never>?

    private var invalidModels: [String] {
        ([config.defaultModel] + config.fallbackModels).filter { !$0.isEmpty && !config.models.contains($0) }
    }

    var body: some View {
        Form {
            Section("隐私与启用") {
                Toggle("启用 AI", isOn: $config.enabled)
                Text("AI 默认关闭。开启后，使用 AI 功能时，您提供的文本会发送至配置的服务，该服务可能转发给上游。刷新模型会发送 API Key；连接测试会发送合成测试文本。请确认信任服务提供方。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("服务") {
                TextField("服务名称", text: $config.name)
                TextField("HTTPS Base URL（例如 https://example.com/v1）", text: $config.baseURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("更改地址并保存时会清除模型列表和选择，并关闭 AI；请重新刷新模型后再启用。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("保存配置") { requestSave() }
            }
            Section("API Key") {
                LabeledContent("Keychain", value: keyStatus)
                SecureField("输入新的 API Key", text: $keyInput)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存 Key") {
                    do {
                        guard config.baseURL == saved.baseURL else { throw AIServiceError.configuration }
                        try service.saveKey(keyInput, expectedEndpoint: saved.baseURL)
                        keyInput = ""
                        message = "Key 已保存到 Keychain。"
                        updateKeyStatus()
                    } catch { message = "保存 Key 失败：\(error.localizedDescription)" }
                }
                TextField("复用来源地址（留空为旧版未绑定 Key）", text: Binding(
                    get: { reuseSource ?? "" },
                    set: { reuseSource = $0.isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                )).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("确认复用已有 Key") { showingReuse = true }
                Text("旧版 Key 不会自动绑定；更换地址后需输入新 Key，或明确确认复用。旧 Key 不会自动删除。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("删除当前地址的 Key", role: .destructive) {
                    do {
                        guard config.baseURL == saved.baseURL else { throw AIServiceError.configuration }
                        try service.removeKey(expectedEndpoint: saved.baseURL)
                        keyInput = ""
                        message = "Key 已删除。"
                        updateKeyStatus()
                    } catch { message = "删除 Key 失败：\(error.localizedDescription)" }
                }
            }
            Section("模型") {
                Button("刷新模型列表") { networkTask = Task { await refreshModels() } }
                if config.models.isEmpty {
                    Text("暂无模型。请先保存服务地址和 Key，然后刷新模型列表。")
                        .foregroundStyle(.orange)
                } else {
                    Picker("默认模型", selection: $config.defaultModel) {
                        Text("请选择").tag("")
                        if !config.defaultModel.isEmpty && !config.models.contains(config.defaultModel) {
                            Text("已失效：\(config.defaultModel)").tag(config.defaultModel)
                        }
                        ForEach(config.models, id: \.self) { model in Text(model).tag(model) }
                    }
                    Text("备用模型按下方顺序尝试；选择默认模型后请保存配置。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(Array(config.fallbackModels.enumerated()), id: \.offset) { index, model in
                        HStack {
                            Text("\(index + 1). \(model)")
                            if !config.models.contains(model) { Text("已失效").foregroundStyle(.orange) }
                            Spacer()
                            Button("上移") { config.fallbackModels.swapAt(index, index - 1) }
                                .disabled(index == 0)
                            Button("移除") { config.fallbackModels.remove(at: index) }
                        }
                    }
                    ForEach(config.models.filter { $0 != config.defaultModel && !config.fallbackModels.contains($0) }, id: \.self) { model in
                        Button("添加备用：\(model)") { config.fallbackModels.append(model) }
                    }
                }
                if !invalidModels.isEmpty {
                    Text("模型已失效：\(invalidModels.joined(separator: "、"))。请重新选择或移除后保存。")
                        .foregroundStyle(.orange)
                }
            }
            Section("连接测试") {
                Button("发送合成文本测试") { networkTask = Task { await testConnection() } }
                Text("测试仅发送固定的合成取件文本，不发送您的真实记录；需要先保存配置并启用 AI。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let message {
                Section("操作结果") { Text(message).textSelection(.enabled) }
            }
        }
        .disabled(busy)
        .navigationTitle("AI 服务设置")
        .onDisappear { networkTask?.cancel(); networkTask = nil }
        .onAppear {
            saved = service.loadConfiguration()
            config = saved
            updateKeyStatus()
        }
        .confirmationDialog("确认将已有 Key 绑定到当前保存的地址？", isPresented: $showingReuse, titleVisibility: .visible) {
            Button("确认复用并绑定") {
                do {
                    guard config.baseURL == saved.baseURL else { throw AIServiceError.configuration }
                    try service.reuseKey(from: reuseSource, expectedEndpoint: saved.baseURL)
                    updateKeyStatus()
                    message = "Key 已绑定到当前地址。"
                } catch { message = "绑定失败：\(error.localizedDescription)" }
            }
        } message: {
            Text("目标地址：\(saved.baseURL)。来源：\(reuseSource ?? "旧版未绑定 Key")。请确认信任目标服务。")
        }
        .alert("确认更换 AI 服务地址？", isPresented: $showingEndpointChange) {
            Button("保留原配置", role: .cancel) { config = saved }
            Button("更换并重新选择模型") { saveConfiguration(privacyConfirmed: false) }
        } message: {
            Text("更换后将关闭 AI 并清除当前模型选择，需为新地址配置密钥、刷新模型。旧地址密钥仍保留在钥匙串；取消不会改变已保存配置。")
        }
        .alert("确认启用 AI？", isPresented: $showingConsent) {
            Button("取消", role: .cancel) { }
            Button("确认并保存") { saveConfiguration(privacyConfirmed: true) }
        } message: {
            Text("使用 AI 时文本将发送到配置的服务，该服务可能转发给上游。请确认您信任该服务并同意此传输。")
        }
    }

    private func updateKeyStatus() {
        do { keyStatus = try service.hasKey() ? "当前地址已绑定（不显示）" : "当前地址未绑定；请重新输入或确认复用" }
        catch { keyStatus = "无法读取"; message = "读取 Keychain 失败：\(error.localizedDescription)" }
    }

    private func requestSave() {
        if !saved.baseURL.isEmpty && config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) != saved.baseURL {
            showingEndpointChange = true
            return
        }
        if config.enabled && !saved.enabled && config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) == saved.baseURL { showingConsent = true }
        else { saveConfiguration(privacyConfirmed: false) }
    }

    private func saveConfiguration(privacyConfirmed: Bool) {
        do {
            let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parts = URLComponents(string: base), parts.scheme?.lowercased() == "https",
                  parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil else { throw AIServiceError.configuration }
            guard !config.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIServiceError.configuration }
            var candidate = config
            let changed = base != saved.baseURL
            if changed { candidate.models = []; candidate.defaultModel = ""; candidate.fallbackModels = []; candidate.enabled = false }
            if candidate.enabled {
                let selected = [config.defaultModel] + config.fallbackModels
                guard !config.defaultModel.isEmpty, Set(selected).count == selected.count,
                      selected.allSatisfy({ config.models.contains($0) }) else { throw AIServiceError.configuration }
            }
            candidate.baseURL = base
            try service.saveConfiguration(candidate, privacyConfirmed: privacyConfirmed)
            if changed && !saved.baseURL.isEmpty { reuseSource = saved.baseURL }
            saved = service.loadConfiguration()
            config = saved
            updateKeyStatus()
            message = "配置已保存。"
        } catch { message = "保存配置失败：\(error.localizedDescription)（请检查名称、HTTPS 地址和模型选择。）" }
    }

    private func readyForNetwork() -> Bool {
        guard keyInput.isEmpty else {
            message = "API Key 输入尚未保存；请先保存或清空输入，避免使用旧 Key。"
            return false
        }
        guard config == saved else {
            message = "配置有未保存的更改；请先保存，避免请求发往错误的服务。"
            return false
        }
        guard service.loadConfiguration() == saved else {
            message = "已保存配置在其他位置发生变化，请返回后重新打开设置。"
            return false
        }
        return true
    }

    @MainActor private func refreshModels() async {
        guard readyForNetwork() else { return }
        busy = true
        defer { busy = false }
        do {
            let models = try await service.refreshModels()
            guard !Task.isCancelled else { return }
            saved = service.loadConfiguration()
            config = saved
            message = "已刷新 \(models.count) 个模型。请检查默认和备用模型。"
        } catch { if !Task.isCancelled { message = "刷新模型失败：\(error.localizedDescription)" } }
    }

    @MainActor private func testConnection() async {
        guard readyForNetwork() else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await service.testConnection()
            guard !Task.isCancelled else { return }
            let failures = result.failures.map { "\($0.model)：\($0.category.localizedDescription)" }.joined(separator: "；")
            message = "连接测试成功，使用模型：\(result.model)。" + (failures.isEmpty ? "" : " 先前模型失败：\(failures)")
        } catch {
            guard !Task.isCancelled else { return }
            let safeError = (error as? AIServiceError) ?? .unavailable
            var details = ""
            if case .allModelsFailed(let failures) = safeError {
                details = failures.map { "\($0.model)：\($0.category.localizedDescription)" }.joined(separator: "；")
            }
            message = "连接测试失败：\(safeError.localizedDescription)" + (details.isEmpty ? "" : "。各模型失败：\(details)")
        }
    }
}
