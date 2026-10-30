import SwiftUI

struct UAPISettingsView: View {
    private let settings = UAPISettingsService()
    @State private var enabled = false
    @State private var key = ""
    @State private var hasKey = false
    @State private var consent = false
    @State private var message: String?
    var body: some View {
        Form {
            Section("UAPI 物流查询") {
                Toggle("启用查询", isOn: Binding(get: { enabled }, set: { value in
                    if value { consent = true }
                    else { run { try settings.setEnabled(false); enabled = false } }
                }))
                Text("查询会将快递单号及必要的收件人手机尾号发送至 uapis.cn。官方文档目前标注每次查询40积分，以实际账户计费为准。不会匿名回退或自动重试计费请求。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("API Key") {
                Text(hasKey ? "已保存到本机钥匙串（不显示）" : "尚未配置密钥")
                SecureField("输入 UAPI API Key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存密钥") { run { try settings.saveKey(key); key = ""; hasKey = try settings.hasKey(); message = "密钥已保存。" } }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("删除密钥", role: .destructive) { run { try settings.removeKey(); hasKey = false; enabled = settings.isEnabled(); message = "密钥已删除。" } }
                Text("密钥不进入JSON备份、日志或快捷指令参数。请勿把密钥提交到公开仓库。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("定时刷新") {
                Text("在快捷指令的个人自动化中运行“刷新未签收快递物流”。先手动运行以完成系统授权。已签收、已归档不参与批量；iOS锁屏和后台执行时长仍受系统限制。")
            }
            if let message { Text(message).textSelection(.enabled) }
        }
        .navigationTitle("UAPI物流查询")
        .onAppear { enabled = settings.isEnabled(); run { hasKey = try settings.hasKey() } }
        .confirmationDialog("允许向 UAPI 发送物流查询信息？", isPresented: $consent, titleVisibility: .visible) {
            Button("同意并启用") { run { try settings.setEnabled(true, privacyConfirmed: true); enabled = true; message = "已启用。" } }
            Button("取消", role: .cancel) {}
        } message: { Text("每次查询会发送单号及本次提供的手机尾号，并可能消耗账户积分。") }
    }
    private func run(_ action: () throws -> Void) {
        do { try action() } catch { message = error.localizedDescription }
    }
}
