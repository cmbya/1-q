import SwiftUI
import WidgetKit

struct WidgetSettingsView: View {
    @EnvironmentObject private var store: ShipmentStore
    @State private var selectionA = ""
    @State private var selectionB = ""
    @State private var message: String?
    @State private var ready = false

    var body: some View {
        Form {
            Section {
                Text("分别设置两个桌面组件的分组，然后在桌面添加“取件组件 A”和“取件组件 B”。同一种组件的多个副本共用该槽位设置。")
                slotPicker(.a, selection: $selectionA)
                slotPicker(.b, selection: $selectionB)
            } footer: {
                Text("分组被删除后，组件会提示重新选择，不会自动切换到其他分组。设置变化会请求刷新，实际刷新时机由系统决定。")
            }
            .disabled(!ready || store.isHistoricalSnapshot)
            Button("刷新桌面组件") {
                for slot in WidgetSlot.allCases { WidgetCenter.shared.reloadTimelines(ofKind: slot.kind) }
            }
            if let message { Text(message).foregroundStyle(.red) }
        }
        .navigationTitle("桌面组件设置")
        .onAppear(perform: load)
    }

    private func slotPicker(_ slot: WidgetSlot, selection: Binding<String>) -> some View {
        Picker(slot.title, selection: Binding(
            get: { selection.wrappedValue },
            set: { newValue in
                guard ready, !store.isHistoricalSnapshot else { return }
                do {
                    let groupID: UUID?
                    if newValue.isEmpty { groupID = nil }
                    else {
                        guard let id = UUID(uuidString: newValue),
                              store.groups.contains(where: { $0.id == id }) else {
                            throw PickupStorageError.notFound
                        }
                        groupID = id
                    }
                    try WidgetSlotBinding().save(groupID, for: slot)
                    selection.wrappedValue = newValue
                    WidgetCenter.shared.reloadTimelines(ofKind: slot.kind)
                    message = nil
                } catch {
                    message = "保存失败：\(error.localizedDescription)"
                }
            }
        )) {
            Text("未绑定").tag("")
            if !selection.wrappedValue.isEmpty,
               !store.groups.contains(where: { $0.id.uuidString == selection.wrappedValue }) {
                Text("原分组已删除，请重选").tag(selection.wrappedValue)
            }
            ForEach(store.groups) { group in Text(group.name).tag(group.id.uuidString) }
        }
    }
    private func load() {
        ready = false
        do {
            let bindings = try WidgetSlotBinding()
            selectionA = try bindings.groupID(for: .a)?.uuidString ?? ""
            selectionB = try bindings.groupID(for: .b)?.uuidString ?? ""
            message = nil
            ready = true
        } catch { message = "无法读取组件设置：\(error.localizedDescription)" }
    }
}
