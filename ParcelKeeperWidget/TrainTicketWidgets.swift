import AppIntents
import Foundation
import SwiftUI
import WidgetKit

struct TrainTicketEntry: TimelineEntry {
    let date: Date
    let slot: TrainWidgetSlot
    let ticket: TrainTicket?
    let message: String?
    let isStorageError: Bool
    var eligibleTicketIDs: [UUID] = []
    var mode: TrainWidgetMode = .automatic
    var isBrowsing: Bool = false
    var canResetBrowsing: Bool = false

    var position: Int {
        guard let id = ticket?.id, let index = eligibleTicketIDs.firstIndex(of: id) else { return 0 }
        return index + 1
    }
}

/// Reads one immutable shared snapshot. Widgets never create/migrate shared data.
struct TrainTicketProvider: TimelineProvider {
    let slot: TrainWidgetSlot

    func placeholder(in context: Context) -> TrainTicketEntry {
        TrainTicketEntry(date: Date(), slot: slot, ticket: nil,
                         message: "请在 App 中添加火车票并设置组件", isStorageError: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (TrainTicketEntry) -> Void) {
        completion(loadTimeline(now: Date()).entries[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrainTicketEntry>) -> Void) {
        completion(loadTimeline(now: Date()))
    }

    private func loadTimeline(now: Date) -> Timeline<TrainTicketEntry> {
        do {
            let groupID = try AppGroupResolver.groupID()
            let snapshot = try SharedPickupStore(appGroupID: groupID, accessMode: .existingSharedData).snapshot()
            let tickets = snapshot.trainTickets ?? []
            let binding = TrainTicketSelection.binding(for: slot, in: snapshot.trainWidgetBindings ?? [])
            // Use the production selection API for both modes: starts reveal tickets,
            // ends hide them even when fixed or manually browsing. The cap includes now.
            let dates = TrainTicketSelection.timelineDates(in: tickets, now: now)
            let entries = dates.map { entry(tickets: tickets, binding: binding, at: $0) }
            // Periodically extend the rolling 24h window. If dates were capped, reload
            // no later than its last covered boundary. WidgetKit scheduling is best effort.
            let refresh = min(now.addingTimeInterval(6 * 60 * 60), dates.last ?? now)
            return Timeline(entries: entries, policy: .after(refresh > now ? refresh : now.addingTimeInterval(6 * 60 * 60)))
        } catch {
            let failure = TrainTicketEntry(date: now, slot: slot, ticket: nil,
                message: "无法读取共享数据，请打开 App 检查共享存储与初始化状态", isStorageError: true)
            return Timeline(entries: [failure], policy: .after(now.addingTimeInterval(30 * 60)))
        }
    }

    private func entry(tickets: [TrainTicket], binding: TrainWidgetBinding, at date: Date) -> TrainTicketEntry {
        let eligible = TrainTicketSelection.eligibleTickets(in: tickets, now: date)
        let selected = TrainTicketSelection.ticket(in: tickets, binding: binding, now: date)
        let message: String?
        if selected != nil {
            message = nil
        } else if binding.mode == .fixed {
            message = "暂无需要展示车票；固定车票未到展示时间、已结束或未绑定。切票将进入手动浏览。"
        } else {
            message = "暂无需要展示车票，请在 App 中添加或检查展示有效期。"
        }
        return TrainTicketEntry(date: date, slot: slot, ticket: selected, message: message,
            isStorageError: false, eligibleTicketIDs: eligible.map(\.id), mode: binding.mode,
            isBrowsing: binding.mode == .automatic && binding.browsingTicketID == selected?.id && selected != nil,
            canResetBrowsing: binding.mode == .fixed || binding.browsingTicketID != nil)
    }
}

struct TrainTicketWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @ScaledMetric(relativeTo: .caption2) private var compactFont: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var regularFont: CGFloat = 14
    let entry: TrainTicketEntry

    private var large: Bool { family == .systemLarge }
    private var spacing: CGFloat { large ? 9 : 2 }
    private var textSize: CGFloat { large ? regularFont : compactFont }
    private var modeLabel: String {
        if entry.mode == .fixed { return "固定 · 切票转手动" }
        return entry.isBrowsing ? "手动浏览" : "自动"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let ticket = entry.ticket {
                ticketContent(ticket)
            } else {
                HStack {
                    Label(entry.slot.title, systemImage: "tram.fill").font(.subheadline)
                    Spacer(minLength: 2)
                    Text(modeLabel).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(entry.isStorageError ? "共享数据读取失败" : "暂无需要展示车票")
                    .font(.subheadline)
                Text(entry.message ?? "请打开 App 检查")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(large ? 5 : 2)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
        // AppIntent buttons take precedence over this background/detail destination.
        .widgetURL(entry.ticket.flatMap { URL(string: "parcelkeeper://train/\($0.id.uuidString)") })
    }

    private var controls: some View {
        HStack(spacing: large ? 10 : 5) {
            Button(intent: BrowseTrainTicketWidgetIntent(slot: entry.slot, direction: -1, expectedTicketID: entry.ticket?.id)) {
                Label("上一张", systemImage: "chevron.left")
            }
            .disabled(entry.isStorageError || entry.eligibleTicketIDs.isEmpty || (entry.ticket != nil && entry.eligibleTicketIDs.count == 1))
            Text("\(entry.position)/\(entry.eligibleTicketIDs.count)")
                .monospacedDigit()
                .accessibilityLabel("第 \(entry.position) 张，共 \(entry.eligibleTicketIDs.count) 张有效车票")
            Button(intent: BrowseTrainTicketWidgetIntent(slot: entry.slot, direction: 1, expectedTicketID: entry.ticket?.id)) {
                Label("下一张", systemImage: "chevron.right")
            }
            .disabled(entry.isStorageError || entry.eligibleTicketIDs.isEmpty || (entry.ticket != nil && entry.eligibleTicketIDs.count == 1))
            Spacer(minLength: 0)
            Button(intent: ResetTrainTicketWidgetBrowsingIntent(slot: entry.slot)) {
                Text("回到自动")
            }
            .disabled(entry.isStorageError || !entry.canResetBrowsing)
        }
        .font(.system(size: large ? 12 : 10))
        .buttonStyle(.plain)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityHint(entry.mode == .fixed ? "上一张或下一张将退出固定模式，进入手动浏览；回到自动显示首张有效车票" : "仅切换展示有效期内的车票，不修改票面")
    }

    private func ticketContent(_ ticket: TrainTicket) -> some View {
        let fields = ticket.fields
        return VStack(alignment: .leading, spacing: spacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(display(fields.trainNumber)).font(large ? .title2.bold() : .subheadline.bold())
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityLabel("车次 \(display(fields.trainNumber))")
                Spacer(minLength: 4)
                Text("\(entry.slot.title) · \(modeLabel)")
                    .font(.system(size: large ? 11 : 9)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            HStack(alignment: .top, spacing: large ? 16 : 8) {
                station(name: fields.departureStation, time: fields.departureTime,
                        date: fields.departureDate, label: "出发")
                station(name: fields.arrivalStation, time: fields.arrivalTime,
                        date: fields.arrivalDate, label: "到达")
            }
            if large { Divider() }
            HStack(alignment: .top, spacing: 6) {
                field("车厢", fields.carriage)
                field("座位", fields.seat)
                field("席别", fields.seatClass)
            }
            HStack(alignment: .top, spacing: 6) {
                field("检票口", fields.gate)
                field("乘客", fields.passenger).privacySensitive()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func station(name: String, time: String, date: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: large ? 4 : 0) {
            Text("\(label) · \(display(name))")
                .font(.system(size: textSize, weight: .medium))
                .lineLimit(large ? 2 : 1).minimumScaleFactor(0.75)
            Text(display(time)).font(large ? .title3.monospacedDigit() : .caption.monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(display(date)).font(.system(size: textSize)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func field(_ label: String, _ value: String) -> some View {
        Text("\(label) \(display(value))")
            .font(.system(size: textSize))
            .lineLimit(large ? 2 : 1).minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("\(label) \(display(value))")
    }

    private func display(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未填写" : value
    }
}

struct TrainTicketWidgetA: Widget {
    init() {}
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TrainWidgetSlot.a.kind, provider: TrainTicketProvider(slot: .a)) {
            TrainTicketWidgetView(entry: $0)
        }
        .configurationDisplayName(TrainWidgetSlot.a.title)
        .description("有效期内自动显示车票，可上一张、下一张手动浏览或回到自动。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TrainTicketWidgetB: Widget {
    init() {}
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TrainWidgetSlot.b.kind, provider: TrainTicketProvider(slot: .b)) {
            TrainTicketWidgetView(entry: $0)
        }
        .configurationDisplayName(TrainWidgetSlot.b.title)
        .description("默认固定车票，仅有效期内展示；点击切票进入手动浏览，可回到自动。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TrainSlots: WidgetBundle {
    var body: some Widget {
        TrainTicketWidgetA()
        TrainTicketWidgetB()
    }
}
