import SwiftUI

/// Self-contained tab entry. A parent can supply an ID binding for widget/deep-link navigation.
struct TrainTicketListView: View {
    @EnvironmentObject private var store: ShipmentStore
    @Binding private var selectedTicketID: UUID?
    @State private var presentedTicket: TrainTicketPresentation?
    @State private var showingAdd = false
    @State private var showingBindings = false
    @State private var showingBatchStart = false

    init(selectedTicketID: Binding<UUID?> = .constant(nil)) {
        _selectedTicketID = selectedTicketID
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                List {
                    if store.isHistoricalSnapshot {
                        Section { Label("当前为历史快照，只能查看，不能修改或设置组件。", systemImage: "lock") }
                    }
                    if let error = store.lastErrorMessage {
                        Section("存储提示") { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    }
                    if store.trainTickets.isEmpty {
                        Section {
                            ContentUnavailableView("还没有火车票", systemImage: "tram", description: Text("手动新增，或粘贴原文识别后核对保存。不会联网查询车票。"))
                        }
                    } else {
                        Section {
                            Button("批量设置展示开始时间") { showingBatchStart = true }
                                .disabled(store.isHistoricalSnapshot)
                            Text("每张票独立展示，不会合并同行或换乘车票。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ticketSection("待出行", historical: false, now: context.date)
                        ticketSection("历史", historical: true, now: context.date)
                    }
                    Section { TrainTicketPrivacyNote() }
                }
            }
            .navigationTitle("火车票")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingBindings = true } label: { Label("A/B 组件", systemImage: "square.grid.2x2") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Label("新增火车票", systemImage: "plus") }
                        .disabled(store.isHistoricalSnapshot)
                }
            }
            .sheet(isPresented: $showingAdd) { TrainTicketEditorView() }
            .sheet(isPresented: $showingBatchStart) { TrainTicketBatchStartView(tickets: store.trainTickets) }
            .sheet(isPresented: $showingBindings) {
                NavigationStack {
                    TrainTicketWidgetSettingsView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingBindings = false } } }
                }
            }
            .sheet(item: $presentedTicket, onDismiss: { selectedTicketID = nil }) { item in
                NavigationStack {
                    TrainTicketDetailView(ticketID: item.id)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { presentedTicket = nil } } }
                }
            }
            .onAppear { openSelectedTicket() }
            .onChange(of: selectedTicketID) { _, _ in openSelectedTicket() }
        }
    }

    private func openSelectedTicket() {
        guard let id = selectedTicketID else { return }
        presentedTicket = TrainTicketPresentation(id: id)
    }

    private func ticketSection(_ title: String, historical: Bool, now: Date) -> some View {
        let tickets = store.trainTickets.filter { isHistory($0, now: now) == historical }
            .sorted { ($0.fields.departure ?? .distantFuture) < ($1.fields.departure ?? .distantFuture) }
        return Section(title) {
            if tickets.isEmpty { Text(historical ? "暂无历史车票" : "暂无待出行车票").foregroundStyle(.secondary) }
            ForEach(tickets) { ticket in
                Button { presentedTicket = TrainTicketPresentation(id: ticket.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(ticket.fields.trainNumber).font(.headline)
                            Spacer()
                            Text(trainTicketStatus(ticket, now: now)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(ticket.fields.departureStation) → \(ticket.fields.arrivalStation)")
                        Text("\(ticket.fields.departureDate)  \(ticket.fields.departureTime)")
                            .font(.subheadline).monospacedDigit()
                        Text("到达：\(ticket.fields.arrivalDate.isEmpty ? "日期未填" : ticket.fields.arrivalDate)  \(ticket.fields.arrivalTime.isEmpty ? "时间未填" : ticket.fields.arrivalTime)")
                            .font(.subheadline).monospacedDigit()
                        Text("车厢：\(ticket.fields.carriage.isEmpty ? "未填" : ticket.fields.carriage) · 座位／铺位：\(ticket.fields.seat.isEmpty ? "未填" : ticket.fields.seat)")
                            .font(.caption)
                        Text("席别：\(ticket.fields.seatClass.isEmpty ? "未填" : ticket.fields.seatClass) · 检票口：\(ticket.fields.gate.isEmpty ? "未填" : ticket.fields.gate)")
                            .font(.caption)
                        Text("乘车人：\(ticket.fields.passenger.isEmpty ? "未填" : ticket.fields.passenger)")
                            .font(.caption).privacySensitive()
                        Text(trainTicketWindowSummary(ticket, now: now))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    private func isHistory(_ ticket: TrainTicket, now: Date) -> Bool {
        ticket.isArchived || ticket.isEnded || (ticket.fields.arrival.map { $0 <= now } == true)
    }
}

private struct TrainTicketPresentation: Identifiable { let id: UUID }

private func trainTicketStatus(_ ticket: TrainTicket, now: Date) -> String {
    if ticket.isArchived { return "已归档" }
    if ticket.isEnded { return "已手动结束" }
    if let arrival = ticket.fields.arrival, arrival <= now { return "计划行程已结束（非乘车确认）" }
    if let departure = ticket.fields.departure, departure <= now { return "已过计划发车时间" }
    return "待出行"
}

private struct TrainTicketPrivacyNote: View {
    var body: some View {
        Text("乘车人信息可能展示在本页及桌面组件，请注意隐私。车次、检票口和时刻均为手动或文本识别结果，不是联网实时信息；晚点、改签与检票请以车站现场及官方信息为准。原文仅留在本次编辑内存中，不随车票保存。")
            .font(.footnote).foregroundStyle(.secondary)
    }
}

struct TrainTicketDetailView: View {
    @EnvironmentObject private var store: ShipmentStore
    let ticketID: UUID
    @State private var editingTicket: TrainTicket?
    @State private var deletingTicket: TrainTicket?
    @State private var message: String?

    var body: some View {
        Group {
            if let ticket = store.trainTickets.first(where: { $0.id == ticketID }) {
                Form {
                    Section("票面信息") { TrainTicketFieldSummary(fields: ticket.fields) }
                    Section("展示状态") {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(trainTicketStatus(ticket, now: context.date))
                                Text(trainTicketWindowSummary(ticket, now: context.date))
                            }
                        }
                        Text("计划到达用于行程分组，并在未自定义结束时间时决定展示结束。按时结束展示不表示您已经乘车或实际到达。晚点时可编辑车票，延长自定义展示结束时间。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("管理") {
                        Button("编辑车票") { editingTicket = store.trainTickets.first { $0.id == ticketID } }
                        Button(ticket.isArchived ? "恢复归档车票" : "归档") {
                            performOnLatest { latest in try store.setTrainTicketArchived(latest, archived: !latest.isArchived) }
                        }
                        Button(ticket.isEnded ? "恢复为未结束" : "手动结束行程") {
                            performOnLatest { latest in try store.setTrainTicketEnded(latest, ended: !latest.isEnded) }
                        }
                        Button("设置展示开始／结束时间（含晚点延长）") { editingTicket = ticket }
                        Text("延长展示不会自动取消归档或手动结束；需要时请先恢复相应状态。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("删除车票", role: .destructive) { deletingTicket = ticket }
                    }
                    .disabled(store.isHistoricalSnapshot)
                    if store.isHistoricalSnapshot { Section { Text("历史快照为只读，管理操作不可用。").foregroundStyle(.secondary) } }
                    if let message { Section("操作结果") { Text(message).foregroundStyle(.red).textSelection(.enabled) } }
                    Section { TrainTicketPrivacyNote() }
                }
            } else {
                ContentUnavailableView("车票不存在", systemImage: "ticket", description: Text("这张车票可能已被删除，或当前存储中没有该记录。请返回列表查看。"))
            }
        }
        .navigationTitle("车票详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingTicket) { TrainTicketEditorView(ticket: $0) }
        .confirmationDialog("永久删除这张车票？", isPresented: Binding(
            get: { deletingTicket != nil },
            set: { if !$0 { deletingTicket = nil } }
        ), titleVisibility: .visible) {
            Button("删除车票", role: .destructive) {
                guard let expected = deletingTicket else { return }
                perform { try store.deleteTrainTicket(id: expected.id, expected: expected) }
                deletingTicket = nil
            }
            Button("取消", role: .cancel) { deletingTicket = nil }
        } message: { Text("删除无法撤销；固定绑定此车票的组件将不再显示这张票。") }
    }

    private func performOnLatest(_ action: (TrainTicket) throws -> Void) {
        guard let latest = store.trainTickets.first(where: { $0.id == ticketID }) else {
            message = "车票已不存在，请返回列表。"
            return
        }
        perform { try action(latest) }
    }

    private func perform(_ action: () throws -> Void) {
        guard !store.isHistoricalSnapshot else { message = "历史快照为只读。"; return }
        do { try action(); message = nil }
        catch { message = error.localizedDescription }
    }
}

private struct TrainTicketFieldSummary: View {
    let fields: TrainTicketFields
    var body: some View {
        Group {
            row("发车日期", fields.departureDate)
            row("车次", fields.trainNumber)
            row("出发站", fields.departureStation)
            row("发车时间", fields.departureTime)
            row("到达站", fields.arrivalStation)
            row("到达日期（辅助）", fields.arrivalDate)
            row("到达时间", fields.arrivalTime)
            row("车厢", fields.carriage)
            row("座位号", fields.seat)
            row("席别", fields.seatClass)
            row("检票口", fields.gate)
            row("乘车人", fields.passenger)
        }
        .textSelection(.enabled)
    }
    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value.isEmpty ? "未填写" : value)
    }
}

struct TrainTicketEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ShipmentStore
    private let original: TrainTicket?
    @State private var fields: TrainTicketFields
    @State private var displayWindow: TrainTicketDisplayWindow
    @State private var customEnd: Bool
    private let initialWindow: TrainTicketDisplayWindow
    @State private var rawText = ""
    @State private var busy = false
    @State private var recognitionTask: Task<Void, Never>?
    @State private var recognitionID: UUID?
    @State private var message: String?
    @State private var discardConfirmation = false
    @State private var replaceConfirmation = false
    private let ai = AIService()

    init(ticket: TrainTicket? = nil) {
        original = ticket
        _fields = State(initialValue: ticket?.fields ?? TrainTicketFields())
        let window = ticket?.displayWindow ?? TrainTicketDisplayWindow(
            enabled: ticket != nil, startsAt: ticket?.widgetStartsAt, endsAt: nil
        )
        initialWindow = window
        _displayWindow = State(initialValue: window)
        _customEnd = State(initialValue: window.endsAt != nil)
    }

    private var hasChanges: Bool {
        fields != (original?.fields ?? TrainTicketFields()) || !rawText.isEmpty
            || displayWindow != initialWindow || customEnd != (initialWindow.endsAt != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("从原文识别") {
                    TextEditor(text: $rawText).frame(minHeight: 110)
                        .accessibilityLabel("车票原文，仅在内存中保留")
                    Button("识别并填写草稿") {
                        if fields != TrainTicketFields() { replaceConfirmation = true }
                        else { recognize() }
                    }
                    .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("AI 已启用时直接使用 AI，失败不会悄悄改用本地规则。AI 关闭时使用本地识别；结果可手动补全。AI 会将原文发送至已配置服务，请先移除不必要的个人信息。")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("编辑火车票 AI 提示词") { TrainTicketPromptView() }
                }
                Section("必填信息") {
                    field("发车日期 *", hint: "yyyy-MM-dd（含年份）", value: $fields.departureDate)
                    field("车次 *", hint: "如 G123", value: $fields.trainNumber)
                    field("出发站 *", hint: "如 北京南", value: $fields.departureStation)
                    field("发车时间 *", hint: "HH:mm", value: $fields.departureTime)
                    field("到达站 *", hint: "如 上海虹桥", value: $fields.arrivalStation)
                    Text("日期不会自动补为今天。原文缺少年份时请核对并完整填写发车日期，再保存。所有时间按中国标准时间（北京时间）。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("其他票面信息") {
                    field("到达日期（辅助）", hint: "yyyy-MM-dd", value: $fields.arrivalDate)
                    field("到达时间", hint: "HH:mm", value: $fields.arrivalTime)
                    Text("到达日期和到达时间需要同时填写或同时留空。跨日行程请填写真实到达日期。")
                        .font(.footnote).foregroundStyle(.secondary)
                    field("车厢", hint: "如 03", value: $fields.carriage)
                    field("座位号", hint: "如 08A", value: $fields.seat)
                    field("席别", hint: "如 二等座", value: $fields.seatClass)
                    field("检票口", hint: "以现场为准", value: $fields.gate)
                    field("乘车人", hint: "可选，注意隐私", value: $fields.passenger)
                }
                TrainTicketWindowEditor(window: $displayWindow, customEnd: $customEnd, arrival: fields.arrival)
                if let message { Section("提示") { Text(message).foregroundStyle(.red).textSelection(.enabled) } }
                Section { TrainTicketPrivacyNote() }
            }
            .disabled(busy || store.isHistoricalSnapshot)
            .overlay { if busy { ProgressView("正在识别…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .navigationTitle(original == nil ? "新增火车票" : "编辑火车票")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(busy || hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(busy ? "取消识别并退出" : "取消") {
                        if hasChanges || busy { discardConfirmation = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(busy || store.isHistoricalSnapshot)
                }
            }
            .confirmationDialog("放弃未保存的车票草稿？", isPresented: $discardConfirmation, titleVisibility: .visible) {
                Button("放弃并退出", role: .destructive) { cancelRecognition(); dismiss() }
                Button("继续编辑", role: .cancel) { }
            }
            .confirmationDialog("识别结果将替换所有票面字段", isPresented: $replaceConfirmation, titleVisibility: .visible) {
                Button("识别并替换草稿", role: .destructive) { recognize() }
                Button("取消", role: .cancel) { }
            } message: { Text("请确认已保留需要的手动输入。识别只替换票面字段，不修改展示开关和开始／结束时间。识别失败会保留现有草稿。") }
            .onDisappear { cancelRecognition() }
        }
    }

    private func field(_ title: String, hint: String, value: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(hint, text: value).multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }

    private func cancelRecognition() {
        recognitionID = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        busy = false
    }

    @MainActor private func recognize() {
        guard !busy, !store.isHistoricalSnapshot else { return }
        let text = rawText
        let useAI = ai.loadConfiguration().enabled
        let requestID = UUID()
        recognitionID = requestID
        busy = true
        message = nil
        recognitionTask = Task { @MainActor in
            defer {
                if recognitionID == requestID { busy = false; recognitionTask = nil; recognitionID = nil }
            }
            do {
                let result = try await TrainTicketRecognition.recognize(text, useAI: useAI) { input in
                    try await ai.extractTrainTicket(input)
                }
                guard !Task.isCancelled, recognitionID == requestID, !store.isHistoricalSnapshot else { return }
                fields = result
                message = "已填写识别草稿，请逐项核对。缺失字段（尤其年份）需手动补全；尚未保存。"
            } catch {
                guard !Task.isCancelled, recognitionID == requestID else { return }
                message = (useAI ? "AI 识别失败，未切换本地规则，现有草稿已保留：" : "本地识别失败，现有草稿已保留：") + error.localizedDescription
            }
        }
    }

    private func save() {
        guard !busy, !store.isHistoricalSnapshot else { message = "当前不可保存。"; return }
        do {
            let validated = try fields.validated()
            if let problem = trainTicketWindowValidation(displayWindow, customEnd: customEnd, arrival: validated.arrival) {
                message = problem
                return
            }
            _ = try store.saveTrainTicket(validated, existing: original, displayWindow: displayWindow)
            cancelRecognition()
            rawText = ""
            dismiss()
        } catch { message = "保存失败：\(error.localizedDescription)" }
    }
}

private let trainTicketBeijingTimeZone = TimeZone(identifier: "Asia/Shanghai")!

private func trainTicketDisplayDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = trainTicketBeijingTimeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date) + "（北京时间）"
}

private func trainTicketWindowSummary(_ ticket: TrainTicket, now: Date) -> String {
    guard ticket.displayWindow?.enabled != false else { return "组件展示已关闭" }
    guard let start = ticket.widgetStartsAt, let end = ticket.widgetEndsAt else {
        return "组件暂不展示：请补全展示开始／结束时间或票面到达时间"
    }
    let status: String
    if ticket.isArchived || ticket.isEnded { status = "归档／手动结束，不展示" }
    else if now < start { status = "尚未开始展示" }
    else if now >= end { status = "展示时间已结束（非乘车确认）" }
    else { status = "在展示时间内" }
    let endMode = ticket.displayWindow?.endsAt == nil ? "跟随票面到达" : "自定义结束"
    return "\(status) · 开始 \(trainTicketDisplayDate(start)) · \(endMode) \(trainTicketDisplayDate(end))"
}

private func trainTicketWindowValidation(_ window: TrainTicketDisplayWindow, customEnd: Bool, arrival: Date?) -> String? {
    guard window.enabled else { return nil }
    guard let start = window.startsAt else { return "请明确选择并确认展示开始时间；不会自动使用今天或发车时间。" }
    if customEnd && window.endsAt == nil { return "请明确选择并确认自定义展示结束时间。" }
    guard let end = window.endsAt ?? arrival else {
        return "已开启组件展示，但没有到达时间。请补全票面到达时间，或设置自定义展示结束时间；也可关闭展示后仅保存票面。"
    }
    guard end > start else { return "展示结束时间必须晚于开始时间。" }
    return nil
}

private struct TrainTicketWindowEditor: View {
    @Binding var window: TrainTicketDisplayWindow
    @Binding var customEnd: Bool
    let arrival: Date?
    @State private var suggestedStart = Date()
    @State private var suggestedEnd = Date()

    var body: some View {
        Section("此票组件展示时间") {
            Toggle("允许此票在组件显示", isOn: $window.enabled)
            Text("新票默认不展示；开启后须明确选择开始时间。自动、固定和手动浏览均遵循此票的展示时间。AI 只填写票面，不更改这里的设置。")
                .font(.footnote).foregroundStyle(.secondary)
            if window.enabled {
                DatePicker("展示开始（北京时间）", selection: Binding(
                    get: { window.startsAt ?? suggestedStart },
                    set: { window.startsAt = $0 }
                ), displayedComponents: [.date, .hourAndMinute])
                if window.startsAt == nil {
                    Text("上方为待确认时间，尚未设置。请调整日期时间或点击确认。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("确认上方时间为展示开始") { window.startsAt = suggestedStart }
                } else if let start = window.startsAt {
                    Text("已设置开始：\(trainTicketDisplayDate(start))").font(.footnote)
                }
                Toggle("自定义展示结束（可延长晚点）", isOn: Binding(
                    get: { customEnd },
                    set: { value in customEnd = value; if !value { window.endsAt = nil } }
                ))
                if customEnd {
                    DatePicker("展示结束（北京时间）", selection: Binding(
                        get: { window.endsAt ?? suggestedEnd },
                        set: { window.endsAt = $0 }
                    ), displayedComponents: [.date, .hourAndMinute])
                    if window.endsAt == nil {
                        Text("上方为待确认时间，尚未设置结束时间。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("确认上方时间为展示结束") { window.endsAt = suggestedEnd }
                    }
                } else {
                    Text(arrival.map { "结束跟随票面到达：\(trainTicketDisplayDate($0))" } ?? "结束跟随票面到达：尚未填写到达时间，请补全或自定义结束时间。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let problem = trainTicketWindowValidation(window, customEnd: customEnd, arrival: arrival) {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                }
            }
            Text("展示时间只控制组件，不代表实际乘车或实际到达。延长展示不会取消归档或手动结束。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .environment(\.timeZone, trainTicketBeijingTimeZone)
    }
}

private struct TrainTicketBatchStartView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ShipmentStore
    // Full snapshots from opening the sheet are passed to the atomic store operation.
    @State private var tickets: [TrainTicket]
    @State private var selectedIDs: Set<UUID> = []
    @State private var startsAt = Date()
    @State private var confirmed = false
    @State private var message: String?

    init(tickets: [TrainTicket]) {
        _tickets = State(initialValue: tickets)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("选择独立车票") {
                    ForEach(tickets) { ticket in
                        Toggle(isOn: Binding(
                            get: { selectedIDs.contains(ticket.id) },
                            set: { value in
                                if value { selectedIDs.insert(ticket.id) } else { selectedIDs.remove(ticket.id) }
                                confirmed = false
                            }
                        )) {
                            VStack(alignment: .leading) {
                                Text("\(ticket.fields.departureDate) \(ticket.fields.trainNumber) \(ticket.fields.departureStation)→\(ticket.fields.arrivalStation)")
                                Text("\(ticket.fields.passenger.isEmpty ? "乘车人未填" : ticket.fields.passenger) · \(ticket.fields.carriage)车 \(ticket.fields.seat)")
                                    .font(.caption).privacySensitive()
                                if ticket.fields.arrival == nil {
                                    Text("无到达时间：须逐票设置自定义结束，不能参与此次批量设置。")
                                        .font(.caption).foregroundStyle(.red)
                                }
                                if ticket.displayWindow?.endsAt != nil {
                                    Text("已有自定义结束；确认后将恢复跟随票面到达。")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
                Section("统一开始时间（北京时间）") {
                    DatePicker("展示开始", selection: $startsAt, displayedComponents: [.date, .hourAndMinute])
                        .onChange(of: startsAt) { _, _ in confirmed = false }
                    Text("本次统一开启显示，结束恢复跟随各票到达时间。已有自定义结束时间也会被替换；不会取消归档或手动结束。缺少到达时间时整批不保存，请先逐票补全或设置自定义结束。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("确认使用上方开始时间，并为所选票开启显示、结束恢复跟随各票到达时间", isOn: $confirmed)
                }
                if let message { Section("提示") { Text(message).foregroundStyle(.red) } }
            }
            .environment(\.timeZone, trainTicketBeijingTimeZone)
            .disabled(store.isHistoricalSnapshot)
            .navigationTitle("批量设置展示开始")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(selectedIDs.isEmpty || !confirmed || store.isHistoricalSnapshot)
                }
            }
        }
    }

    private func save() {
        guard !store.isHistoricalSnapshot, confirmed, !selectedIDs.isEmpty else { return }
        let selected = tickets.filter { selectedIDs.contains($0.id) }
        guard selected.allSatisfy({ $0.fields.arrival != nil }) else {
            message = "未保存任何车票：所选票中有未填到达时间的票。请逐票设置自定义结束时间，或补全到达时间后再批量设置。"
            return
        }
        let window = TrainTicketDisplayWindow(enabled: true, startsAt: startsAt, endsAt: nil)
        for ticket in selected {
            if let problem = trainTicketWindowValidation(window, customEnd: false, arrival: ticket.fields.arrival) {
                message = "未保存任何车票：\(ticket.fields.trainNumber) \(problem)"
                return
            }
        }
        do {
            try store.setTrainTicketDisplayWindow(window, for: selected)
            dismiss()
        } catch { message = "整批保存失败，未覆盖车票，请重新打开后核对：\(error.localizedDescription)" }
    }
}

struct TrainTicketWidgetSettingsView: View {
    @EnvironmentObject private var store: ShipmentStore
    var body: some View {
        Form {
            Section {
                Text("A、B 是独立的火车票组件，不影响取件组件。默认 A 自动选择待出行车票，B 固定且未绑定；可将 B 固定为另一张票。两槽均选自动时可能显示同一张票。固定模式只展示所选车票；中、大号组件可手动浏览独立车票，不会合并同行或换乘票。自动、固定及手动浏览都遵循每票的显示开关、开始和结束时间，归档或手动结束的票不展示。")
                Text("修改下方选项不会立即写入；每个槽位都需点击保存。保存自动／固定设置会清除该槽当前手动浏览的车票。")
            }
            TrainTicketSlotEditor(slot: .a)
            TrainTicketSlotEditor(slot: .b)
            if store.isHistoricalSnapshot { Section { Text("历史快照为只读，不能保存组件设置。").foregroundStyle(.secondary) } }
            Section { TrainTicketPrivacyNote() }
        }
        .navigationTitle("火车票 A/B 组件")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TrainTicketSlotEditor: View {
    @EnvironmentObject private var store: ShipmentStore
    let slot: TrainWidgetSlot
    @State private var mode: TrainWidgetMode = .automatic
    @State private var ticketID: UUID?
    @State private var baselineMode: TrainWidgetMode = .automatic
    @State private var baselineTicketID: UUID?
    @State private var baselineBrowsingTicketID: UUID?
    @State private var loaded = false
    @State private var message: String?

    var body: some View {
        Section(slot.title) {
            Picker("展示方式", selection: $mode) {
                Text("自动选择").tag(TrainWidgetMode.automatic)
                Text("固定车票").tag(TrainWidgetMode.fixed)
            }
            if mode == .fixed {
                Picker("固定车票", selection: $ticketID) {
                    Text("不绑定车票").tag(Optional<UUID>.none)
                    if let ticketID, !store.trainTickets.contains(where: { $0.id == ticketID }) {
                        Text("原车票已不存在，请重选").tag(Optional(ticketID))
                    }
                    ForEach(store.trainTickets) { ticket in
                        Text("\(ticket.fields.departureDate) \(ticket.fields.trainNumber) \(ticket.fields.departureStation)→\(ticket.fields.arrivalStation) · \(trainTicketStatus(ticket, now: Date()))")
                            .tag(Optional(ticket.id))
                    }
                }
                Text("已归档或已结束的固定票不会作为待出行票展示；解除固定请选“不绑定车票”并保存。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("保存\(slot.title)设置") { save() }
                .disabled(!loaded || store.isHistoricalSnapshot)
            Button("重新读取已保存设置（放弃此槽草稿）") { load() }
            if let message { Text(message).font(.footnote).textSelection(.enabled) }
        }
        .disabled(store.isHistoricalSnapshot)
        .onAppear { if !loaded { load() } }
    }

    private func load() {
        let binding = TrainTicketSelection.binding(for: slot, in: store.trainWidgetBindings)
        mode = binding.mode
        ticketID = binding.ticketID
        baselineMode = binding.mode
        baselineTicketID = binding.ticketID
        baselineBrowsingTicketID = binding.browsingTicketID
        loaded = true
        message = nil
    }

    private func save() {
        guard loaded, !store.isHistoricalSnapshot else { message = "当前不可保存。"; return }
        let current = TrainTicketSelection.binding(for: slot, in: store.trainWidgetBindings)
        guard current.mode == baselineMode, current.ticketID == baselineTicketID,
              current.browsingTicketID == baselineBrowsingTicketID else {
            message = "此槽位已在其他位置更改，未覆盖。请先重新读取，再确认并保存。"
            return
        }
        if mode == .fixed, let ticketID, !store.trainTickets.contains(where: { $0.id == ticketID }) {
            message = "所选车票已不存在，请重新选择或解除绑定。"
            return
        }
        do {
            let binding = TrainWidgetBinding(slot: slot, mode: mode, ticketID: mode == .fixed ? ticketID : nil, browsingTicketID: nil)
            let expected = TrainWidgetBinding(slot: slot, mode: baselineMode, ticketID: baselineTicketID, browsingTicketID: baselineBrowsingTicketID)
            try store.setTrainWidgetBinding(binding, expected: expected)
            let saved = TrainTicketSelection.binding(for: slot, in: store.trainWidgetBindings)
            guard saved.mode == binding.mode, saved.ticketID == binding.ticketID,
                  saved.browsingTicketID == binding.browsingTicketID else {
                message = "设置未能确认，请重新读取后检查。"
                return
            }
            baselineMode = saved.mode
            baselineTicketID = saved.ticketID
            baselineBrowsingTicketID = saved.browsingTicketID
            mode = saved.mode
            ticketID = saved.ticketID
            message = "已保存。桌面组件更新可能需要一点时间。"
        } catch { message = "保存失败，草稿保留：\(error.localizedDescription)" }
    }
}
