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

struct WidgetGroup: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "取件分组")
    static var defaultQuery = WidgetGroupQuery()
    let id: UUID
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    init(_ group: PickupGroup) { id = group.id; name = group.name }
}

struct WidgetGroupQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [WidgetGroup] {
        let groups = try WidgetStore.open().snapshot().groups
        return identifiers.compactMap { id in groups.first(where: { $0.id == id }).map(WidgetGroup.init) }
    }
    func suggestedEntities() async throws -> [WidgetGroup] {
        try WidgetStore.open().snapshot().groups.sorted {
            $0.sortOrder == $1.sortOrder ? $0.id.uuidString < $1.id.uuidString : $0.sortOrder < $1.sortOrder
        }.map(WidgetGroup.init)
    }
}

struct PickupWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "选择取件分组"
    static var description = IntentDescription("显示一个分组的待取件码。")
    @Parameter(title: "分组") var group: WidgetGroup?
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
    func snapshot(for configuration: PickupWidgetConfiguration, in context: Context) async -> PickupEntry { load(configuration) }
    func timeline(for configuration: PickupWidgetConfiguration, in context: Context) async -> Timeline<PickupEntry> {
        Timeline(entries: [load(configuration)], policy: .after(Date().addingTimeInterval(900)))
    }
    private func load(_ configuration: PickupWidgetConfiguration) -> PickupEntry {
        guard let selected = configuration.group else {
            return PickupEntry(date: Date(), groupID: nil, title: "取件码", records: [], message: "长按组件选择分组", error: nil)
        }
        do {
            let priorError = try WidgetStore.error(selected.id)
            let data = try WidgetStore.open().snapshot()
            guard let group = data.groups.first(where: { $0.id == selected.id }) else {
                return PickupEntry(date: Date(), groupID: selected.id, title: selected.name, records: [], message: "分组已失效，请重新配置", error: priorError)
            }
            let records = data.records.filter { $0.groupID == group.id && !$0.isCompleted && !$0.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }
            return PickupEntry(date: Date(), groupID: group.id, title: group.name, records: records,
                               message: records.isEmpty ? "暂无待取件码" : nil, error: priorError)
        } catch {
            return PickupEntry(date: Date(), groupID: selected.id, title: selected.name, records: [],
                               message: "无法读取数据，请打开 App 检查共享容器及初始化状态。", error: "无法读取组件状态或数据，请打开 App 检查")
        }
    }
}

struct PickupWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PickupEntry
    private var capacity: Int { family == .systemSmall ? 1 : family == .systemMedium ? 2 : 4 }
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
                                Text(record.code).font(.subheadline.bold()).lineLimit(1)
                                if !record.location.isEmpty { Text(record.location).font(.caption2).lineLimit(1) }
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

#if !WIDGET_DIAGNOSTICS
@main
#endif
struct ParcelKeeperWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ParcelKeeperPickupWidget", intent: PickupWidgetConfiguration.self, provider: PickupProvider()) { entry in
            PickupWidgetView(entry: entry)
        }
        .configurationDisplayName("待取件码")
        .description("查看指定分组的待取件码，并标记完成。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
