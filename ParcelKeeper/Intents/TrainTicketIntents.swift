import AppIntents
import Foundation
import WidgetKit

/// Append-only shortcut path; the UI has its own edit API. No raw recognition text is persisted.
enum TrainTicketWriter {
    @discardableResult
    static func save(_ input: TrainTicketFields, to store: SharedPickupStore,
                     reloadWidgets: () -> Void = {
                         for slot in TrainWidgetSlot.allCases { WidgetCenter.shared.reloadTimelines(ofKind: slot.kind) }
                     }) throws -> TrainTicket {
        let fields: TrainTicketFields
        do { fields = try input.validated() }
        catch { throw TrainTicketRecognitionError.incomplete }
        try Task.checkCancellation()
        let ticket = TrainTicket(fields: fields, isArchived: false, isEnded: false, keepVisible: false,
                                 displayWindow: TrainTicketDisplayWindow(enabled: false))
        try store.transaction { dataset in
            var tickets = dataset.trainTickets ?? []
            guard !tickets.contains(where: { $0.fields.duplicateIdentity == fields.duplicateIdentity }) else {
                throw TrainTicketRecognitionError.duplicate
            }
            tickets.append(ticket)
            dataset.trainTickets = tickets
        }
        // SharedPickupStore verifies the complete persisted dataset inside its lock before returning.
        reloadWidgets()
        return ticket
    }
}

struct RecognizeTrainTicketIntent: AppIntent {
    static var title: LocalizedStringResource = "识别并添加火车票"
    static var description = IntentDescription("从单张火车票原文识别并新增，不覆盖已有车票。AI 开启时直接使用 AI，关闭时仅本地识别；缺少完整乘车日期时请在 App 补齐。")
    @Parameter(title: "原始文本") var text: String
    @Parameter(title: "写入前确认", default: true) var confirmBeforeSaving: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try SharedPickupStore(appGroupID: nil, accessMode: .existingSharedData)
        _ = try store.snapshot() // Fail before recognition if the main app has not initialized shared data.
        let ai = AIService()
        let draft = try await TrainTicketRecognition.recognize(text, useAI: ai.loadConfiguration().enabled) {
            try await ai.extractTrainTicket($0)
        }
        let fields: TrainTicketFields
        do { fields = try draft.validated() }
        catch { throw TrainTicketRecognitionError.incomplete }
        if confirmBeforeSaving {
            let dialog: IntentDialog = "新增火车票：出发日期 \(fields.departureDate)，车次 \(fields.trainNumber)，出发站 \(fields.departureStation)，发车时间 \(fields.departureTime)，到达站 \(fields.arrivalStation)，到达日期 \(fields.arrivalDate.isEmpty ? "未提供" : fields.arrivalDate)，到达时间 \(fields.arrivalTime.isEmpty ? "未提供" : fields.arrivalTime)，车厢 \(fields.carriage.isEmpty ? "未提供" : fields.carriage)，座位 \(fields.seat.isEmpty ? "未提供" : fields.seat)，席别 \(fields.seatClass.isEmpty ? "未提供" : fields.seatClass)，检票口 \(fields.gate.isEmpty ? "未提供" : fields.gate)，乘车人 \(fields.passenger.isEmpty ? "未提供" : fields.passenger)。不会覆盖已有车票。"
            if #available(iOS 18.0, *) { try await requestConfirmation(dialog: dialog) }
            else { try await requestConfirmation(result: .result(dialog: dialog), showPrompt: true) }
        }
        try Task.checkCancellation()
        _ = try TrainTicketWriter.save(fields, to: store)
        return .result(dialog: "火车票已识别并新增。小组件展示尚未开启，请在 App 中设置展示时间。")
    }
}
