import AppIntents
import Foundation
import SwiftUI
import WidgetKit

private enum WidgetStore {
    static var groupID: String? { Bundle.main.object(forInfoDictionaryKey: "ParcelKeeperAppGroup") as? String }
    static func open() throws -> SharedPickupStore {
        try SharedPickupStore(appGroupID: groupID, accessMode: .existingSharedData)
    }
    static func errorKey(_ group: UUID) -> String { "widget.error." + group.uuidString }
    static func defaults() throws -> UserDefaults {
        guard let id = groupID, !id.isEmpty, let defaults = UserDefaults(suiteName: id) else {
            throw PickupStorageError.invalidData("组件状态不可用，请打开 App 检查共享配置")
        }
        return defaults
    }
    static func error(_ group: UUID) throws -> String? {
        try defaults().string(forKey: errorKey(group))
    }
    static func setError(_ message: String?, group: UUID) throws {
        let defaults = try defaults()
        if let message = message { defaults.set(message, forKey: errorKey(group)) }
        else { defaults.removeObject(forKey: errorKey(group)) }
    }
}

// Reference: evcc-io/app, targets/widget/Configuration.swift.
// A plain String parameter avoids AppEntity registration/rehydration while
// keeping independent per-widget configuration. Labels may change; IDs do not.
struct PickupGroupOptions: DynamicOptionsProvider {
    func results() async throws -> IntentItemCollection<String> {
        let groups = try WidgetStore.open().snapshot().groups.sorted {
            $0.sortOrder == $1.sortOrder ? $0.id.uuidString < $1.id.uuidString : $0.sortOrder < $1.sortOrder
        }
        return IntentItemCollection(sections: [
            IntentItemSection(items: groups.map { group in
                IntentItem<String>(group.id.uuidString,
                    title: LocalizedStringResource(stringLiteral: group.name))
            })
        ])
    }
}

// New configuration type: do not reinterpret a previously saved entity as a
// String. Existing tiles can still be removed without modifying stored records.
struct PickupGroupSelection: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "选择取件分组"
    static var description = IntentDescription("每个组件独立选择一个分组。")
    @Parameter(title: "分组", optionsProvider: PickupGroupOptions()) var groupID: String?
    static var parameterSummary: some ParameterSummary { Summary { \.$groupID } }
    init() {}
}

struct OpenPickupAppIntent: AppIntent {
    static var title: LocalizedStringResource = "打开快递管家"
    static var openAppWhenRun: Bool = true
    func perform() async throws -> some IntentResult { .result() }
}

struct CompletePickupIntent: AppIntent {
    static var title: LocalizedStringResource = "标记取件完成"
    @Parameter(title: "分组 ID") var groupID: String
    @Parameter(title: "记录 ID") var recordID: String
    init() {}
    init(groupID: UUID, recordID: UUID) {
        self.groupID = groupID.uuidString
        self.recordID = recordID.uuidString
    }
    func perform() async throws -> some IntentResult {
        guard let group = UUID(uuidString: groupID), let record = UUID(uuidString: recordID) else {
            throw PickupStorageError.invalidData("组件参数无效，请重新配置组件")
        }
        do {
            _ = try WidgetStore.defaults()
            let store = try WidgetStore.open()
            try store.transaction { data in
                guard data.groups.contains(where: { $0.id == group }),
                      let index = data.records.firstIndex(where: { $0.id == record && $0.groupID == group }) else {
                    throw PickupStorageError.notFound
                }
                data.records[index].isCompleted = true
                data.records[index].updatedAt = Date()
            }
        } catch {
            // Keep the stored message generic: errors may contain private data.
            do { try WidgetStore.setError("标记失败，请打开 App 检查后重试", group: group) }
            catch {
                WidgetCenter.shared.reloadAllTimelines()
                throw PickupStorageError.invalidData("组件状态不可用，无法确认操作结果，请打开 App 检查")
            }
            WidgetCenter.shared.reloadAllTimelines()
            throw PickupStorageError.invalidData("标记失败，请打开 App 检查后重试")
        }
        // The transaction committed; clearing feedback must not be reported as a failed completion.
        do { try WidgetStore.setError(nil, group: group) }
        catch {
            WidgetCenter.shared.reloadAllTimelines()
            throw PickupStorageError.invalidData("取件已标记完成，但组件状态刷新失败，请打开 App 核对")
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct PickupEntry: TimelineEntry {
    let date: Date
    let groupID: UUID?
    let title: String
    let records: [PickupRecord]
    let message: String?
    let error: String?
}

struct PickupProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PickupEntry {
        PickupEntry(date: Date(), groupID: nil, title: "取件码", records: [], message: "选择分组", error: nil)
    }
    func snapshot(for configuration: PickupGroupSelection, in context: Context) async -> PickupEntry { load(configuration) }
    func timeline(for configuration: PickupGroupSelection, in context: Context) async -> Timeline<PickupEntry> {
        Timeline(entries: [load(configuration)], policy: .after(Date().addingTimeInterval(900)))
    }
    private func load(_ configuration: PickupGroupSelection) -> PickupEntry {
        guard let selected = configuration.groupID, let selectedID = UUID(uuidString: selected) else {
            return PickupEntry(date: Date(), groupID: nil, title: "取件码", records: [], message: "长按组件选择分组", error: nil)
        }
        do {
            let priorError = try WidgetStore.error(selectedID)
            let data = try WidgetStore.open().snapshot()
            guard let group = data.groups.first(where: { $0.id == selectedID }) else {
                return PickupEntry(date: Date(), groupID: selectedID, title: "取件码", records: [], message: "分组已失效，请重新配置", error: priorError)
            }
            let records = data.records.filter { $0.groupID == group.id && !$0.isCompleted && !$0.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }
            return PickupEntry(date: Date(), groupID: group.id, title: group.name, records: records,
                               message: records.isEmpty ? "暂无待取件码" : nil, error: priorError)
        } catch {
            return PickupEntry(date: Date(), groupID: selectedID, title: "取件码", records: [],
                               message: "无法读取数据，请打开 App 检查共享容器及初始化状态。", error: "无法读取组件状态或数据，请打开 App 检查")
        }
    }
}

struct PickupWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PickupEntry
    private var capacity: Int { family == .systemSmall ? 3 : family == .systemMedium ? 3 : 7 }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title).font(.headline).lineLimit(1)
            if let error = entry.error {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                    .accessibilityLabel("操作错误：\(error)")
            }
            if let message = entry.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            } else {
                ForEach(Array(entry.records.prefix(capacity))) { record in
                    HStack(spacing: 4) {
                        if let group = entry.groupID {
                            Button(intent: CompletePickupIntent(groupID: group, recordID: record.id)) {
                                Image(systemName: "checkmark.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("标记取件码 \(record.code) 完成")
                            .privacySensitive()
                        }
                        Button(intent: OpenPickupAppIntent()) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(record.code).font(.system(size: family == .systemSmall ? 12 : 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                if !record.location.isEmpty { Text(record.location).font(.system(size: family == .systemSmall ? 9 : 11)).lineLimit(1) }
                            }
                        }
                        .buttonStyle(.plain)
                        .privacySensitive()
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("打开 App")
                        Spacer(minLength: 0)
                    }
                }
                if entry.records.count > capacity {
                    Text("还有 \(entry.records.count - capacity) 条，打开 App 查看")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// Retained only for opt-in diagnostic comparisons, not in the normal bundle.
struct ParcelKeeperWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ParcelKeeperPickupWidget", intent: PickupGroupSelection.self, provider: PickupProvider()) { entry in
            PickupWidgetView(entry: entry)
        }
        .configurationDisplayName("待取件码")
        .description("查看指定分组的待取件码，并标记完成。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
