import AppIntents
import Foundation

enum ShortcutShipmentState: String, AppEnum {
    case automatic, inTransit, outForDelivery, readyForPickup, delivered, exception
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "物流状态")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .automatic: "从物流信息判断", .inTransit: "运输中", .outForDelivery: "派送中",
        .readyForPickup: "待取件", .delivered: "已签收／已完成", .exception: "异常"
    ]
    var shipmentStatus: ShipmentStatus? {
        switch self {
        case .automatic: return nil
        case .inTransit: return .inTransit
        case .outForDelivery: return .outForDelivery
        case .readyForPickup: return .readyForPickup
        case .delivered: return .delivered
        case .exception: return .exception
        }
    }
}

struct AddShipmentIntent: AppIntent {
    static var title: LocalizedStringResource = "添加或更新快递"
    static var description = IntentDescription("接收单号、服务商和最新物流。同单号覆盖传入字段，不存在则新增；不联网查询物流。")
    @Parameter(title: "快递单号") var trackingNumber: String
    @Parameter(title: "快递服务商") var carrierName: String?
    @Parameter(title: "最新物流信息") var logisticsInfo: String?
    @Parameter(title: "物流状态", default: .automatic) var state: ShortcutShipmentState
    @Parameter(title: "物流发生时间") var logisticsTime: Date?
    @Parameter(title: "写入前确认", default: true) var confirmBeforeSaving: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = try ShipmentShortcutService.live()
        let input = try service.validate(.init(trackingNumber: trackingNumber, carrierName: carrierName,
            logisticsInfo: logisticsInfo, status: state.shipmentStatus, logisticsTime: logisticsTime))
        if confirmBeforeSaving {
            let dialog: IntentDialog = "保存快递：\(input.trackingNumber)，服务商：\(input.carrierName ?? "未提供")，状态：\(input.status?.rawValue ?? "保留原状态／新增为运输中")，物流：\(input.logisticsInfo ?? "未提供")。同单号将更新。"
            if #available(iOS 18.0, *) { try await requestConfirmation(dialog: dialog) }
            else { try await requestConfirmation(result: .result(dialog: dialog), showPrompt: true) }
        }
        try Task.checkCancellation()
        let inserted = try service.upsert(input)
        if inserted { return .result(dialog: "快递已新增。") }
        return .result(dialog: "快递已更新。")
    }
}

struct RecognizeShipmentIntent: AppIntent {
    static var title: LocalizedStringResource = "识别并添加或更新快递"
    static var description = IntentDescription("识别一票快递的原文或 minis JSON。选取最新物流，同单号更新；存在歧义时不保存。")
    @Parameter(title: "原始文本") var text: String
    @Parameter(title: "写入前确认", default: true) var confirmBeforeSaving: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = try ShipmentShortcutService.live()
        var input = try ShipmentShortcutParser.parse(text)
        let ai = AIService()
        // AI only fills missing fields. It never chooses among multiple parcels
        // or replaces an already selected latest event with an older one.
        if ai.loadConfiguration().enabled && (input.logisticsInfo == nil || input.carrierName == nil) {
            do {
                let extra = try await ai.extractShipment(text)
                guard extra.trackingNumber == input.trackingNumber else { throw AIServiceError.invalidResponse }
                if input.carrierName == nil { input.carrierName = extra.carrierName }
                // Never attach an AI event to a different locally supplied
                // timestamp/status (including structured JSON with missing info).
                if input.logisticsInfo == nil,
                   input.logisticsTime == nil || input.logisticsTime == extra.logisticsTime,
                   input.status == nil || input.status == extra.status {
                    input.logisticsInfo = extra.logisticsInfo
                    if input.logisticsTime == nil { input.logisticsTime = extra.logisticsTime }
                    if input.status == nil { input.status = extra.status }
                }
            } catch is CancellationError { throw CancellationError() }
            catch AIServiceError.cancelled { throw AIServiceError.cancelled }
            catch {
                // A local tracking number remains usable if enrichment fails.
                // With no local logistics, do not pretend AI produced a status.
            }
        }
        input = try service.validate(input)
        if confirmBeforeSaving {
            let dialog: IntentDialog = "保存快递：\(input.trackingNumber)，服务商：\(input.carrierName ?? "未识别")，状态：\(input.status?.rawValue ?? "未识别，保留原值")，物流：\(input.logisticsInfo ?? "未识别")。同单号将更新。"
            if #available(iOS 18.0, *) { try await requestConfirmation(dialog: dialog) }
            else { try await requestConfirmation(result: .result(dialog: dialog), showPrompt: true) }
        }
        try Task.checkCancellation()
        let inserted = try service.upsert(input)
        if inserted { return .result(dialog: "快递已识别并新增。") }
        return .result(dialog: "快递已识别并更新。")
    }
}
