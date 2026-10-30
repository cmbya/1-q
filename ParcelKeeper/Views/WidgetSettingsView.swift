import SwiftUI
import WidgetKit

struct WidgetSettingsView: View {
    @EnvironmentObject private var store: ShipmentStore
    @State private var selections: [WidgetSlot: String] = [:]
    @State private var message: String?
    @State private var ready = false
    var body: some View {
        Form {
            Section {
                Text("预置 A–J 共 10 个独立槽位。选择分组后，在桌面添加同名组件。选择未绑定即清除此槽位配置，不删除记录；同一槽位的副本共用设置。")
                ForEach(WidgetSlot.allCases) { slot in slotPicker(slot) }
            } footer: {
                Text("旧 A/B 设置保留。分组删除后需重新绑定。App 无法替你移除已添加到桌面的组件。")
            }
            .disabled(!ready || store.isHistoricalSnapshot)
            Button("刷新桌面组件") { WidgetCenter.shared.reloadAllTimelines() }
            if let message { Text(message).foregroundStyle(.red) }
        }
        .navigationTitle("桌面组件设置")
        .onAppear(perform: load)
    }
    private func slotPicker(_ slot: WidgetSlot) -> some View {
        Picker(slot.title, selection: Binding(
            get: { selections[slot] ?? "" },
            set: { value in
                guard ready, !store.isHistoricalSnapshot else { return }
                do {
                    let id: UUID?
                    if value.isEmpty { id = nil }
                    else {
                        guard let uuid = UUID(uuidString: value), store.groups.contains(where: { $0.id == uuid }) else { throw PickupStorageError.notFound }
                        id = uuid
                    }
                    try WidgetSlotBinding().save(id, for: slot)
                    selections[slot] = value
                    WidgetCenter.shared.reloadTimelines(ofKind: slot.kind)
                    message = nil
                } catch { message = "保存失败：\(error.localizedDescription)" }
            }
        )) {
            Text("未绑定").tag("")
            let selected = selections[slot] ?? ""
            if !selected.isEmpty, !store.groups.contains(where: { $0.id.uuidString == selected }) {
                Text("原分组已删除，请重选").tag(selected)
            }
            ForEach(store.groups) { group in Text(group.name).tag(group.id.uuidString) }
        }
    }
    private func load() {
        ready = false
        do {
            let bindings = try WidgetSlotBinding()
            var loaded: [WidgetSlot: String] = [:]
            for slot in WidgetSlot.allCases { loaded[slot] = try bindings.groupID(for: slot)?.uuidString ?? "" }
            selections = loaded
            message = nil
            ready = true
        } catch { message = "无法读取组件设置：\(error.localizedDescription)" }
    }
}
