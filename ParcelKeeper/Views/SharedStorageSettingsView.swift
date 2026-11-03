import SwiftUI

struct SharedStorageSettingsView: View {
    @EnvironmentObject private var store: ShipmentStore
    @State private var items: [AppGroupResolver.Candidate] = []
    @State private var message: String?
    @State private var pending: String?
    @State private var connecting = false
    @State private var operationID: UUID?
    var body: some View {
        Form {
            Section {
                Text("全能签重签后，应用从描述文件取得候选组，再以系统容器访问结果过滤。这里不会增加证书权限。")
                Text("共享组可能被同证书的其他应用共用，取件码和地址存在被同组应用访问的风险。首次使用请明确确认；已有数据不自动切换或合并。")
                    .foregroundStyle(.orange)
            }
            Section("当前可访问共享组") {
                ForEach(items, id: \.id) { item in
                    VStack(alignment: .leading) {
                        Text(item.id).font(.caption).textSelection(.enabled)
                        if item.hasData { Text("存在取件数据，将沿用此组").font(.caption) }
                        if item.selected { Text("已确认使用").font(.caption) }
                        Button(item.hasData || item.selected ? "连接现有数据" : "使用这个共享组") { pending = item.id }
                            .disabled(connecting || store.reminderOperationInProgress)
                    }
                }
            }
            if let message { Text(message) }
            Button("重新检测") { load() }
                .disabled(connecting)
        }
        .navigationTitle("共享存储适配")
        .onAppear(perform: load)
        .onDisappear { operationID = nil; pending = nil; connecting = false }
        .confirmationDialog("确认使用该共享组？组内数据可能被其他获授权应用访问。", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            Button("确认并连接") {
                guard let id = pending, !connecting, !store.reminderOperationInProgress else { return }
                pending = nil
                let operation = UUID()
                operationID = operation
                connecting = true
                Task { @MainActor in
                    defer { if operationID == operation { connecting = false; operationID = nil } }
                    guard operationID == operation else { return }
                    do {
                        try AppGroupResolver.choose(id)
                        let warnings = try await store.reconnectSharedStorage()
                        guard operationID == operation else { return }
                        load()
                        message = warnings.isEmpty
                            ? "已连接共享数据并完成提醒对账。现在可到桌面组件设置绑定 A–J。"
                            : "已连接共享数据，但提醒对账未完成：\n" + warnings.joined(separator: "\n")
                    } catch {
                        guard operationID == operation else { return }
                        message = error.localizedDescription
                    }
                }
            }
            Button("取消", role: .cancel) { pending = nil }
        }
    }
    private func load() {
        do {
            items = try AppGroupResolver.candidates()
            message = items.isEmpty ? AppGroupResolver.ResolutionError.noAccess.localizedDescription : nil
        } catch { items = []; message = error.localizedDescription }
    }
}
