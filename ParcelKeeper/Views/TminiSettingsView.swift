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
                Text("仅明确选择 Tmini 时查询。单号及调用密钥发送至 api.tmini.net，不读取或发送本票手机尾号。每次查询是一笔可能计费的 GET 请求，不自动重试、不回退其他渠道。启用或保存密钥不会发送测试或余额请求。")
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
                Text("密钥仅存本机 Keychain，不进入 JSON 备份或诊断日志。文档要求在 GET 的 Query 参数中传递密钥：HTTPS 保护传输，但平台及其代理仍可看到完整请求地址；请只使用可信密钥并自行管理账户权限。")
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
                Text("每次向 Tmini 发起单号查询按 4 积分累计；重复查询重复记，批量按实际发起的单号数记。网络失败、无轨迹或平台拒绝也保留本次记账。未配置、格式错误或请求发起前取消不计。仅统计本设备此功能加入后的调用，更换或清除密钥不清零，不含其他设备或平台外调用。")
                    .font(.footnote)
                Text("本地估算，非平台账单或余额。平台可能不对失败请求收费；为避免漏记，在请求交给网络前先落账，若此刻取消或退出也可能多记一次。实际扣费以平台为准。记账仅存共享容器，不随业务 JSON 备份导入导出。")
                    .font(.footnote)
            }
            Section("使用与验证范围") {
                Text("快递详情可设置本票默认渠道，或仅本次选择 Tmini；单票及批量快捷指令也可强制选择 Tmini。旧票、旧快捷指令默认渠道不变。价格、额度与实际扣费以平台控制台为准；App 不查询余额，也不复用 UAPI 积分。未做真实付费查询，不能保证所有快递或取件码均可获取。接口返回的取件码、地址仅显示为查询说明，不自动写入个人字段。")
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
        } message: { Text("后续明确选择此渠道时发送单号及密钥，以 HTTPS GET 调用；请求地址含密钥且可能计费。无手机尾号、无自动回退或重试。") }
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
