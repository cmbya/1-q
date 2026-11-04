import SwiftUI

struct TminiSettingsView: View {
    private let settings = TminiSettingsService()
    private let usageStore = TminiUsageStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var usage: TminiUsageSummary?
    @State private var usageError: String?
    @State private var enabled = false
    @State private var key = ""
    @State private var hasKey = false
    @State private var consent = false
    @State private var message: String?
    var body: some View {
        Form {
            Section("独立付费渠道") {
                Toggle("启用 Tmini", isOn: Binding(get: { enabled }, set: { value in
                    if value { consent = true }
                    else { run { try settings.setEnabled(false) } }
                }))
                Text("4积分/次，实际扣费以平台为准。")
                    .font(.footnote)
            }
            Section("调用密钥") {
                Text(hasKey ? "已保存在本机钥匙串（不显示）" : "尚未配置密钥")
                SecureField("输入 Tmini Key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存密钥（不查询）") {
                    run { try settings.saveKey(key); key = ""; message = "密钥已保存并通过本机回读验证。" }
                }.disabled(key.isEmpty)
                Button("清除密钥并停用", role: .destructive) {
                    run { try settings.removeKey(); key = ""; message = "密钥已清除并通过本机回读验证。" }
                }
                Text("密钥仅保存在本机。")
                    .font(.footnote)
            }
            Section("本地调用记账") {
                if let usage {
                    LabeledContent("累计查询次数", value: "\(usage.queries) 次")
                    LabeledContent("累计记账积分", value: "\(usage.points) 积分")
                    if let date = usage.firstRecordedAt { LabeledContent("开始记账", value: ShipmentDateDisplay.string(date)) }
                    if let date = usage.lastRecordedAt { LabeledContent("最近记账", value: ShipmentDateDisplay.string(date)) }
                }
                if let usageError { Text(usageError).foregroundStyle(.red) }
                Button("刷新记账显示（不查询）") { loadUsage() }
                Text("每次发起查询记账4积分。")
                    .font(.footnote)
                Text("本地估算，不代表平台余额。")
                    .font(.footnote)
            }
            Section("使用与验证范围") {
                Text("在快递详情选择 Tmini 刷新。")
                    .font(.footnote)
                Link("Tmini 接口文档", destination: URL(string: "https://api.tmini.net/detail/2")!)
            }
            if let message { Text(message) }
        }
        .navigationTitle("Tmini物流查询")
        .onAppear { run {}; loadUsage() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { loadUsage() } }
        .confirmationDialog("允许 Tmini 付费查询？", isPresented: $consent, titleVisibility: .visible) {
            Button("同意并启用（不查询）") { run { try settings.setEnabled(true, privacyConfirmed: true) } }
            Button("取消", role: .cancel) {}
        } message: { Text("查询会发送运单号和密钥，4积分/次。") }
    }
    private func run(_ action: () throws -> Void) {
        do { try action(); hasKey = try settings.hasKey() }
        catch { message = (error as? TminiError)?.localizedDescription ?? "Tmini 设置操作失败。" }
        enabled = settings.isEnabled()
    }
    private func loadUsage() {
        do { usage = try usageStore.summary(); usageError = nil }
        catch { usage = nil; usageError = "无法读取本地记账；未显示为零，也未清空已有统计。" }
    }
}

