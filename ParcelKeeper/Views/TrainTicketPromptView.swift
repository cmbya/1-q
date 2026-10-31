import SwiftUI

/// Only edits the train-ticket semantic prompt. Never changes the provider, models or AI enablement.
struct TrainTicketPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var saved = ""
    @State private var loaded = false
    @State private var showingReset = false
    @State private var showingDiscard = false
    @State private var message: String?
    private let service = AIService()

    private var dirty: Bool { draft != saved }
    private var invalid: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 12000
    }

    var body: some View {
        Form {
            Section("独立的火车票 AI 提示词") {
                Text("仅用于火车票识别，不影响取件码提示词、服务地址、密钥、模型及 AI 开关。保存后从下一次请求起生效。")
                    .font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $draft)
                    .frame(minHeight: 300)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("火车票 AI 提示词")
                HStack {
                    Text("\(draft.count) / 12000 字")
                    Spacer()
                    if dirty { Text("未保存") }
                }.font(.caption).foregroundStyle(invalid ? Color.red : Color.secondary)
            }
            Section {
                Button("保存提示词") { save() }.disabled(!loaded || invalid || !dirty)
                Button("恢复默认提示词", role: .destructive) { showingReset = true }
                    .disabled(!loaded)
            } footer: {
                Text("不得为空，最多 12000 字。固定 JSON 输出和安全约束由服务另行提供，无法通过编辑此提示词移除。不要在提示词中写入真实姓名、证件号或 API Key。")
            }
            if let message { Section("操作结果") { Text(message).textSelection(.enabled) } }
        }
        .navigationTitle("火车票 AI 提示词")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(dirty)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { if dirty { showingDiscard = true } else { dismiss() } }
            }
        }
        .onAppear {
            guard !loaded else { return }
            saved = service.loadTrainTicketPrompt()
            draft = saved
            loaded = true
        }
        .confirmationDialog("恢复默认火车票提示词？", isPresented: $showingReset, titleVisibility: .visible) {
            Button("恢复默认并保存", role: .destructive) {
                service.resetTrainTicketPrompt()
                let result = service.loadTrainTicketPrompt()
                guard result == AIService.defaultTrainTicketPrompt else {
                    message = "恢复后读取结果不一致，请重新打开检查；当前草稿未丢弃。"
                    return
                }
                saved = result
                draft = result
                message = "已恢复并保存默认火车票提示词。AI 开关和其他提示词未更改。"
            }
            Button("取消", role: .cancel) { }
        } message: { Text("这会立即移除已保存的自定义火车票提示词，并丢弃本页未保存的编辑；不会修改取件码提示词。") }
        .confirmationDialog("提示词有未保存的更改", isPresented: $showingDiscard, titleVisibility: .visible) {
            Button("保存并返回") { if save() { dismiss() } }.disabled(invalid)
            Button("放弃更改并返回", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) { }
        }
    }

    @discardableResult private func save() -> Bool {
        guard loaded, !invalid else { message = "提示词不能为空，且最多 12000 字。"; return false }
        do {
            try service.saveTrainTicketPrompt(draft)
            let result = service.loadTrainTicketPrompt()
            guard result == draft else { message = "保存后读取结果不一致，请重试；草稿已保留。"; return false }
            saved = result
            message = "火车票提示词已保存，将用于下一次 AI 识别。"
            return true
        } catch {
            message = "保存失败，草稿已保留：\(error.localizedDescription)"
            return false
        }
    }
}
