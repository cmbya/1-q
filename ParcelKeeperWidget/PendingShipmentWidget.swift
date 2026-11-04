import AppIntents
import SwiftUI
import WidgetKit

struct PendingShipmentEntry: TimelineEntry {
    let date: Date
    let shipment: Shipment?
    let ids: [UUID]
    let browsing: Bool
    let error: Bool
    var position: Int { shipment.flatMap { ids.firstIndex(of: $0.id) }.map { $0 + 1 } ?? 0 }
}

struct PendingShipmentProvider: TimelineProvider {
    func placeholder(in context: Context) -> PendingShipmentEntry {
        .init(date: Date(), shipment: nil, ids: [], browsing: false, error: false)
    }
    func getSnapshot(in context: Context, completion: @escaping (PendingShipmentEntry) -> Void) { completion(load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PendingShipmentEntry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(Date().addingTimeInterval(900))))
    }
    private func load() -> PendingShipmentEntry {
        do {
            let group = try AppGroupResolver.groupID()
            let data = try SharedPickupStore(appGroupID: group, accessMode: .existingSharedData).snapshot()
            return .init(date: Date(), shipment: PendingShipmentSelection.selected(in: data),
                         ids: PendingShipmentSelection.eligible(data.shipments).map(\.id),
                         browsing: PendingShipmentSelection.isBrowsing(in: data), error: false)
        } catch {
            return .init(date: Date(), shipment: nil, ids: [], browsing: false, error: true)
        }
    }
}

struct BrowsePendingShipmentIntent: AppIntent {
    static var title: LocalizedStringResource = "切换未签收快递"
    static var openAppWhenRun = false
    static var isDiscoverable = false
    @Parameter(title: "方向") var direction: Int
    @Parameter(title: "当前快递") var expectedID: String
    init() {}
    init(direction: Int, id: UUID?) { self.direction = direction; self.expectedID = id?.uuidString ?? "" }
    func perform() async throws -> some IntentResult {
        guard expectedID.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil,
              let id = UUID(uuidString: expectedID) else { throw PickupStorageError.staleCompletion }
        let group = try AppGroupResolver.groupID()
        try SharedPickupStore(appGroupID: group, accessMode: .existingSharedData)
            .browsePendingShipment(direction: direction, expectedID: id)
        WidgetCenter.shared.reloadTimelines(ofKind: PendingShipmentSelection.kind)
        return .result()
    }
}
struct ResetPendingShipmentIntent: AppIntent {
    static var title: LocalizedStringResource = "未签收快递回到自动"
    static var openAppWhenRun = false
    static var isDiscoverable = false
    @Parameter(title: "当前快递") var expectedID: String?
    @Parameter(title: "手动浏览") var expectedBrowsing: Bool?
    init() {}
    init(id: UUID?, browsing: Bool) {
        self.expectedID = id?.uuidString
        self.expectedBrowsing = browsing
    }
    func perform() async throws -> some IntentResult {
        guard let expectedID, let browsing = expectedBrowsing,
              expectedID.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil,
              let id = UUID(uuidString: expectedID) else { throw PickupStorageError.staleCompletion }
        let group = try AppGroupResolver.groupID()
        try SharedPickupStore(appGroupID: group, accessMode: .existingSharedData)
            .resetPendingShipmentBrowsing(expected: .init(selectedID: id, browsing: browsing))
        WidgetCenter.shared.reloadTimelines(ofKind: PendingShipmentSelection.kind)
        return .result()
    }
}

struct PendingShipmentWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PendingShipmentEntry
    private var large: Bool { family == .systemLarge }
    var body: some View {
        VStack(alignment: .leading, spacing: large ? 10 : 4) {
            HStack {
                Label("未签收快递", systemImage: "shippingbox")
                    .font(.subheadline.bold())
                Spacer()
                Text(entry.browsing ? "手动浏览" : "自动").font(.caption2).foregroundStyle(.secondary)
            }
            if let shipment = entry.shipment {
                HStack {
                    Text(shipment.carrierName).font(.subheadline.bold()).lineLimit(1)
                    Spacer()
                    Label(shipment.statusDisplayText, systemImage: shipment.status.systemImage).font(.caption)
                }
                Text(shipment.trackingNumber).font(.caption.monospaced()).lineLimit(1).minimumScaleFactor(0.7).privacySensitive()
                if !shipment.note.isEmpty {
                    Text(shipment.note).font(.caption).lineLimit(large ? 3 : 1).privacySensitive()
                }
                Text(shipment.logisticsInfo.flatMap { $0.isEmpty ? nil : $0 } ?? "暂无物流信息，请在 App 中刷新")
                    .font(.caption).lineLimit(large ? 7 : 2).privacySensitive()
                if let time = shipment.logisticsTime {
                    Text("物流更新：\(ShipmentDateDisplay.string(time))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if large, let time = shipment.lastQueriedAt {
                    Text("最近查询：\(ShipmentDateDisplay.string(time))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(entry.error ? "共享数据读取失败，请打开 App 检查" : "暂无未签收快递")
                    .font(.subheadline)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button(intent: BrowsePendingShipmentIntent(direction: -1, id: entry.shipment?.id)) {
                    Label("上一票", systemImage: "chevron.left")
                }.disabled(entry.error || entry.ids.count < 2)
                Text("\(entry.position)/\(entry.ids.count)").monospacedDigit()
                    .accessibilityLabel("第\(entry.position)票，共\(entry.ids.count)票未签收快递")
                Button(intent: BrowsePendingShipmentIntent(direction: 1, id: entry.shipment?.id)) {
                    Label("下一票", systemImage: "chevron.right")
                }.disabled(entry.error || entry.ids.count < 2)
                Spacer(minLength: 0)
                Button(intent: ResetPendingShipmentIntent(id: entry.shipment?.id, browsing: entry.browsing)) { Text("回到自动") }
                    .disabled(entry.error || !entry.browsing)
            }.font(.caption2).buttonStyle(.plain).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "parcelkeeper://shipments"))
    }
}
struct PendingShipmentWidget: Widget {
    init() {}
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PendingShipmentSelection.kind, provider: PendingShipmentProvider()) {
            PendingShipmentWidgetView(entry: $0)
        }
        .configurationDisplayName("未签收快递")
        .description("显示已保存的物流，多票可上一票／下一票切换。不会自动发起付费查询。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
