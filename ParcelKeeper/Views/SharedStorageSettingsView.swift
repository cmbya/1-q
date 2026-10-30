import SwiftUI

struct SharedStorageSettingsView: View {
    @EnvironmentObject private var store: ShipmentStore
    @State private var items: [AppGroupResolver.Candidate] = []
    @State private var message: String?
    @State private var pending: String?
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
                    }
                }
            }
            if let message { Text(message) }
            Button("重新检测") { load() }
        }
        .navigationTitle("共享存储适配")
        .onAppear(perform: load)
        .confirmationDialog("确认使用该共享组？组内数据可能被其他获授权应用访问。", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            Button("确认并连接") {
                guard let id = pending else { return }
                pending = nil
                do {
                    try AppGroupResolver.choose(id)
                    try store.reconnectSharedStorage()
                    load()
                    message = "已连接共享数据。现在可到桌面组件设置绑定 A–J。"
                } catch { message = error.localizedDescription }
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
