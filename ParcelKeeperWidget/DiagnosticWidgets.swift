#if WIDGET_DIAGNOSTICS
import AppIntents
import Foundation
import OSLog
import SwiftUI
import WidgetKit

// Test-only widgets. D1/D2 are read-only summaries; D3/D4 isolate production paths.
private struct DiagnosticEntry: TimelineEntry {
    let date: Date
    let status: String
    let detail: String
    var operationError: String? = nil
}

private struct DiagnosticProvider: TimelineProvider {
    let readsSharedData: Bool

    func placeholder(in context: Context) -> DiagnosticEntry {
        DiagnosticEntry(date: Date(), status: "诊断占位（非运行结果）", detail: "等待时间线")
    }

    func getSnapshot(in context: Context, completion: @escaping (DiagnosticEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DiagnosticEntry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(Date().addingTimeInterval(60))))
    }

    private func load() -> DiagnosticEntry {
        guard readsSharedData else {
            return DiagnosticEntry(date: Date(), status: "组件运行正常", detail: "D1 · 不读取共享数据")
        }
        do {
            // Same selected-group policy as production, including re-signed groups.
            let group = try AppGroupResolver.groupID()
            let store = try SharedPickupStore(appGroupID: group, accessMode: .existingSharedData)
            let data = try store.snapshot()
            let count = data.records.filter { !$0.isCompleted }.count
            return DiagnosticEntry(date: Date(), status: "共享数据读取成功",
                                   detail: "D2 · 分组 \(data.groups.count) · 待取 \(count)")
        } catch {
            // Do not expose raw errors: paths and shipment data may be private.
            return DiagnosticEntry(date: Date(), status: "共享数据读取失败", detail: "D2 · 共享组选择、授权或数据异常，请到 App 检查")
        }
    }
}

private struct DiagnosticView: View {
    let entry: DiagnosticEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.status).font(.headline)
            Text(entry.detail).font(.caption)
            if entry.operationError != nil {
                // Presence only: never render persisted/raw error contents.
                Text("操作失败，请打开 App 核对后重试")
                    .font(.caption2).foregroundStyle(.red)
                    .accessibilityLabel("操作错误：请打开 App 核对后重试")
            }
            Text(entry.date, style: .time).font(.caption2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(Color.blue.opacity(0.12), for: .widget)
    }
}

private struct StaticDiagnosticWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ParcelKeeperDiagnosticStatic", provider: DiagnosticProvider(readsSharedData: false)) {
            DiagnosticView(entry: $0)
        }
        .configurationDisplayName("诊断①静态显示")
        .description("不读共享数据、不带交互，测试组件基础运行。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ReadOnlyDiagnosticWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ParcelKeeperDiagnosticReadOnly", provider: DiagnosticProvider(readsSharedData: true)) {
            DiagnosticView(entry: $0)
        }
        .configurationDisplayName("诊断②只读数据")
        .description("只读取共享数据，显示结果与数量，不显示取件码或地址。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// D3 isolates the legacy AppIntent provider, not the production A–J slots.
private struct ConfiguredTextDiagnosticWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ParcelKeeperDiagnosticConfiguredText", intent: PickupGroupSelection.self, provider: PickupProvider()) { entry in
            DiagnosticView(entry: DiagnosticEntry(date: entry.date,
                status: "分组时间线已返回", detail: "D3 · 记录 \(entry.records.count) · \(entry.message == nil ? "有数据" : "请到 App 检查分组或共享数据")",
                operationError: entry.error == nil ? nil : "操作失败"))
        }
        .configurationDisplayName("诊断③分组纯文字")
        .description("选择分组后只显示纯文字，隔离原交互视图。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// D4 keeps the production view but bypasses AppIntent configuration and UserDefaults.
private struct OriginalViewDiagnosticProvider: TimelineProvider {
    func placeholder(in context: Context) -> PickupEntry {
        PickupEntry(date: Date(), groupID: nil, title: "D4 占位", records: [], message: "非运行结果", error: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (PickupEntry) -> Void) { completion(load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PickupEntry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(Date().addingTimeInterval(60))))
    }
    private func load() -> PickupEntry {
        do {
            let group = Bundle.main.object(forInfoDictionaryKey: "ParcelKeeperAppGroup") as? String
            let data = try SharedPickupStore(appGroupID: group, accessMode: .existingSharedData).snapshot()
            guard let selected = data.groups.sorted(by: { $0.sortOrder < $1.sortOrder }).first else {
                return PickupEntry(date: Date(), groupID: nil, title: "D4", records: [], message: "没有分组", error: nil)
            }
            let records = data.records.filter { $0.groupID == selected.id && !$0.isCompleted && !$0.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return PickupEntry(date: Date(), groupID: selected.id, title: "D4 · \(selected.name)", records: records,
                               message: records.isEmpty ? "暂无待取件码" : nil, error: nil)
        } catch {
            return PickupEntry(date: Date(), groupID: nil, title: "D4", records: [], message: "共享数据读取失败", error: nil)
        }
    }
}

private struct OriginalViewDiagnosticWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ParcelKeeperDiagnosticOriginalView", provider: OriginalViewDiagnosticProvider()) {
            PickupWidgetView(entry: $0)
        }
        .configurationDisplayName("诊断④原界面")
        .description("自动读取首个分组，保留原按钮和界面；点击完成会真实修改记录，请只用测试数据。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct MinimalConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Minimal configuration"
    @Parameter(title: "Label", default: "CONFIG-ALPHA") var label: String
}

private struct MinimalProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DiagnosticEntry {
        DiagnosticEntry(date: Date(), status: "MINIMAL-PLACEHOLDER", detail: "Not a timeline result")
    }
    func snapshot(for configuration: MinimalConfiguration, in context: Context) async -> DiagnosticEntry {
        Logger(subsystem: "com.dinghao.ParcelKeeper", category: "widget-probe").notice("minimal snapshot reached")
        return DiagnosticEntry(date: Date(), status: "MINIMAL-CONFIG-OK", detail: configuration.label)
    }
    func timeline(for configuration: MinimalConfiguration, in context: Context) async -> Timeline<DiagnosticEntry> {
        Logger(subsystem: "com.dinghao.ParcelKeeper", category: "widget-probe").notice("minimal timeline reached")
        return Timeline(entries: [DiagnosticEntry(date: Date(), status: "MINIMAL-CONFIG-OK", detail: configuration.label)], policy: .never)
    }
}

private struct MinimalConfiguredWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ParcelKeeperMinimalConfigured", intent: MinimalConfiguration.self, provider: MinimalProvider()) {
            DiagnosticView(entry: $0)
        }
        .configurationDisplayName("Minimal configuration probe")
        .description("No entities, shared storage, or buttons")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct ParcelKeeperDiagnosticBundle: WidgetBundle {
    var body: some Widget {
        MinimalConfiguredWidget()
        diagnosisWidgets()
        productionSlots()
    }
    // Actual A–J configurations/providers/views, not D3 substitutes.
    @WidgetBundleBuilder
    private func productionSlots() -> some Widget {
        firstSlots()
        lastSlots()
    }
    @WidgetBundleBuilder
    private func firstSlots() -> some Widget {
        SlotWidget(slot: .a)
        SlotWidget(slot: .b)
        SlotWidget(slot: .c)
        SlotWidget(slot: .d)
        SlotWidget(slot: .e)
    }
    @WidgetBundleBuilder
    private func lastSlots() -> some Widget {
        SlotWidget(slot: .f)
        SlotWidget(slot: .g)
        SlotWidget(slot: .h)
        SlotWidget(slot: .i)
        SlotWidget(slot: .j)
    }
    @WidgetBundleBuilder
    private func diagnosisWidgets() -> some Widget {
        StaticDiagnosticWidget()
        ReadOnlyDiagnosticWidget()
        ConfiguredTextDiagnosticWidget()
        OriginalViewDiagnosticWidget()
        ParcelKeeperWidget()
    }
}
#endif
