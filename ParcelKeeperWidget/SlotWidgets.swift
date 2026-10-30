import Foundation
import SwiftUI
import WidgetKit

struct SlotProvider: TimelineProvider {
    let slot: WidgetSlot
    func placeholder(in context: Context) -> PickupEntry {
        PickupEntry(date: Date(), groupID: nil, title: slot.title, records: [], message: "请在 App 设置中绑定分组", error: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (PickupEntry) -> Void) { completion(load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PickupEntry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(Date().addingTimeInterval(900))))
    }
    private func load() -> PickupEntry {
        do {
            guard let selected = try WidgetSlotBinding().groupID(for: slot) else {
                return placeholderEntry("请打开 App → 设置 → 桌面组件，绑定此组件的分组")
            }
            let group = Bundle.main.object(forInfoDictionaryKey: "ParcelKeeperAppGroup") as? String
            let data = try SharedPickupStore(appGroupID: group, accessMode: .existingSharedData).snapshot()
            guard let selectedGroup = data.groups.first(where: { $0.id == selected }) else {
                return placeholderEntry("绑定分组已删除，请到 App 重新选择")
            }
            let records = data.records.filter {
                $0.groupID == selected && !$0.isCompleted && !$0.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }
            let groupDefaults = group.flatMap { UserDefaults(suiteName: $0) }
            let error = groupDefaults?.string(forKey: "widget.error." + selected.uuidString)
            return PickupEntry(date: Date(), groupID: selected, title: selectedGroup.name, records: records,
                               message: records.isEmpty ? "暂无待取件码" : nil, error: error)
        } catch {
            return placeholderEntry("读取失败，请打开 App 检查共享数据或重新绑定分组")
        }
    }
    private func placeholderEntry(_ message: String) -> PickupEntry {
        PickupEntry(date: Date(), groupID: nil, title: slot.title, records: [], message: message, error: nil)
    }
}

struct SlotWidget: Widget {
    let slot: WidgetSlot
    init() { self.slot = .a }
    init(slot: WidgetSlot) { self.slot = slot }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: slot.kind, provider: SlotProvider(slot: slot)) { PickupWidgetView(entry: $0) }
            .configurationDisplayName(slot == .a ? "取件组件 A" : "取件组件 B")
            .description("分组在 App 设置内独立绑定，支持显示取件码与地点并标记完成。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#if !WIDGET_DIAGNOSTICS
@main
struct PickupSlotBundle: WidgetBundle {
    var body: some Widget {
        SlotWidget(slot: .a)
        SlotWidget(slot: .b)
    }
}
#endif
