#if WIDGET_DIAGNOSTICS
import Foundation
import SwiftUI
import WidgetKit

// Test-only widgets: no AppIntent configuration, buttons, writes or parcel details.
private struct DiagnosticEntry: TimelineEntry {
    let date: Date
    let status: String
    let detail: String
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
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ParcelKeeperAppGroup") as? String,
              !group.isEmpty else {
            return DiagnosticEntry(date: Date(), status: "共享组配置缺失", detail: "D2 · Info.plist")
        }
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil else {
            return DiagnosticEntry(date: Date(), status: "共享容器不可访问", detail: "D2 · 请核对组件签名授权")
        }
        do {
            let store = try SharedPickupStore(appGroupID: group, accessMode: .existingSharedData)
            let data = try store.snapshot()
            let count = data.records.filter { !$0.isCompleted }.count
            return DiagnosticEntry(date: Date(), status: "共享数据读取成功",
                                   detail: "D2 · 分组 \(data.groups.count) · 待取 \(count)")
        } catch {
            // Do not expose raw errors: paths and shipment data may be private.
            return DiagnosticEntry(date: Date(), status: "容器可访问，读取失败", detail: "D2 · 初始化、锁或数据格式异常")
        }
    }
}

private struct DiagnosticView: View {
    let entry: DiagnosticEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.status).font(.headline)
            Text(entry.detail).font(.caption)
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

@main
struct ParcelKeeperDiagnosticBundle: WidgetBundle {
    var body: some Widget {
        StaticDiagnosticWidget()
        ReadOnlyDiagnosticWidget()
        ParcelKeeperWidget()
    }
}
#endif
