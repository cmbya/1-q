import Foundation
import SwiftUI
import WidgetKit

struct TrainTicketEntry: TimelineEntry {
    let date: Date
    let slot: TrainWidgetSlot
    let ticket: TrainTicket?
    let message: String?
    let isStorageError: Bool
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
            let horizon = now.addingTimeInterval(24 * 60 * 60)
            // Fixed bindings deliberately retain the selected ticket after arrival.
            // Automatic bindings change at arrival, never merely at departure.
            let boundaries: [Date] = binding.mode == .automatic ? Array(Set(tickets.compactMap { ticket -> Date? in
                guard !ticket.isArchived, !ticket.isEnded, !ticket.keepVisible,
                      let arrival = ticket.fields.arrival, arrival > now, arrival <= horizon else { return nil }
                return arrival
            })).sorted() : []
            let scheduled = Array(boundaries.prefix(20))
            let entries = ([now] + scheduled).map { date in
                entry(tickets: tickets, binding: binding, at: date)
            }
            // Prebuilt entries perform the switch even if WidgetKit delays a reload.
            // If capped, request fresh data by the last covered boundary, not after
            // an omitted arrival. Reload dates are system hints, not timers.
            let refresh: Date
            if binding.mode == .fixed {
                refresh = now.addingTimeInterval(6 * 60 * 60)
            } else if boundaries.count > scheduled.count, let coveredUntil = scheduled.last {
                refresh = min(now.addingTimeInterval(6 * 60 * 60), coveredUntil)
            } else {
                refresh = min(now.addingTimeInterval(6 * 60 * 60), horizon)
            }
            return Timeline(entries: entries, policy: .after(refresh))
        } catch {
            let failure = TrainTicketEntry(date: now, slot: slot, ticket: nil,
                message: "无法读取共享数据，请打开 App 检查共享存储与初始化状态", isStorageError: true)
            return Timeline(entries: [failure], policy: .after(now.addingTimeInterval(30 * 60)))
        }
    }

    private func entry(tickets: [TrainTicket], binding: TrainWidgetBinding, at date: Date) -> TrainTicketEntry {
        let selected = TrainTicketSelection.ticket(in: tickets, binding: binding, now: date)
        let message: String?
        if selected != nil {
            message = nil
        } else if binding.mode == .fixed {
            message = binding.ticketID == nil
                ? "尚未绑定火车票，请在 App 中为此组件选择一张票"
                : "绑定火车票已失效，请打开 App 重新选择"
        } else {
            message = "暂无可显示的火车票，请在 App 中添加或检查行程状态"
        }
        return TrainTicketEntry(date: date, slot: slot, ticket: selected, message: message, isStorageError: false)
    }
}

struct TrainTicketWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @ScaledMetric(relativeTo: .caption2) private var compactFont: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var regularFont: CGFloat = 14
    let entry: TrainTicketEntry

    private var large: Bool { family == .systemLarge }
    private var spacing: CGFloat { large ? 12 : 3 }
    private var textSize: CGFloat { large ? regularFont : compactFont }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let ticket = entry.ticket {
                ticketContent(ticket)
            } else {
                Label(entry.slot.title, systemImage: "tram.fill").font(.headline)
                Spacer(minLength: 0)
                Label(entry.isStorageError ? "共享数据读取失败" : "未显示火车票",
                      systemImage: entry.isStorageError ? "exclamationmark.triangle" : "ticket")
                    .font(.subheadline)
                Text(entry.message ?? "请打开 App 检查")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(entry.ticket.flatMap { URL(string: "parcelkeeper://train/\($0.id.uuidString)") })
    }

    private func ticketContent(_ ticket: TrainTicket) -> some View {
        let fields = ticket.fields
        return VStack(alignment: .leading, spacing: spacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(display(fields.trainNumber)).font(large ? .title2.bold() : .subheadline.bold())
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityLabel("车次 \(display(fields.trainNumber))")
                Spacer(minLength: 4)
                Text(entry.slot.title).font(.caption2).foregroundStyle(.secondary)
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
            if large { Spacer(minLength: 0) }
        }
        .accessibilityElement(children: .contain)
    }

    private func station(name: String, time: String, date: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: large ? 4 : 1) {
            Text("\(label) · \(display(name))")
                .font(.system(size: textSize, weight: .medium))
                .lineLimit(large ? 3 : 2).fixedSize(horizontal: false, vertical: true)
            Text(display(time)).font(large ? .title3.monospacedDigit() : .caption.monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(display(date)).font(.system(size: textSize)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func field(_ label: String, _ value: String) -> some View {
        // Compact inline labels avoid six stacked label/value rows on medium.
        Text("\(label) \(display(value))")
            .font(.system(size: textSize))
            .lineLimit(large ? 3 : 2).minimumScaleFactor(0.85)
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
        .description("在 App 中设置自动显示下一行程，或固定一张火车票；到达后自动切换。")
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
        .description("在 App 中独立绑定火车票；默认固定模式，不自动选择其他车票。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TrainSlots: WidgetBundle {
    var body: some Widget {
        TrainTicketWidgetA()
        TrainTicketWidgetB()
    }
}
