import AppIntents
import Foundation

/// Optional intent parameters keep previously saved shortcuts compatible.
enum QueryChannelChoice: String, AppEnum {
    case automatic
    case platformOnly
    case uapi
    case tmini

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "查询渠道")
    static var caseDisplayRepresentations: [QueryChannelChoice: DisplayRepresentation] = [
        .automatic: "跟随来源（使用本票默认设置）",
        .platformOnly: "仅商城（不使用付费接口）",
        .uapi: "强制UAPI（可能消耗积分）",
        .tmini: "强制Tmini（付费查询）"
    ]
    var mode: TrackingRefreshMode {
        switch self {
        case .automatic: return .automatic
        case .platformOnly: return .platformOnly
        case .uapi: return .uapi
        case .tmini: return .tmini
        }
    }
}

extension Optional where Wrapped == QueryChannelChoice {
    var resolvedMode: TrackingRefreshMode { self?.mode ?? .automatic }
}

/// Presentation never infers a courier from a platform, or a live node from a status.
enum ShipmentRefreshPresentation {
    static func origin(_ shipment: Shipment) -> String {
        switch shipment.originPlatform {
        case "taobao": return "淘宝"
        case "jd": return "京东"
        case "pdd": return "拼多多"
        case "uapi": return "UAPI"
        case nil, "", "manual": return "原UAPI／未关联"
        default: return "未关联（未知来源）"
        }
    }
    static func source(_ shipment: Shipment) -> String {
        switch shipment.logisticsSource {
        case "tmini": return "Tmini"
        case "kdyzm": return "取件助手后台（京东）"
        case "taobao": return "淘宝"
        case "jd": return "京东"
        case "pdd": return "拼多多"
        case "uapi": return "UAPI"
        case nil, "": return shipment.lastQueriedAt == nil ? "未关联" : "原UAPI（旧记录）"
        default: return "未知来源"
        }
    }
    static func result(_ shipment: Shipment, newlyDelivered: Bool, isCached: Bool = false) -> String {
        let oldText = isCached ? "使用本地成功查询缓存；未联网、未新增收费，保留原查询时间。" : (newlyDelivered ? "物流已更新，本次新增签收。" : "物流已更新。")
        return oldText + "\n" + details(shipment)
    }
    static func details(_ shipment: Shipment) -> String {
        var lines = ["\(shipment.carrierName) · \(shipment.trackingNumber)", "状态：\(shipment.status.rawValue)"]
        let info = shipment.logisticsInfo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lines.append(info.isEmpty ? "暂无物流轨迹（状态不代表实时物流）。" : "最新物流：\(info)")
        lines.append("来源：\(source(shipment))")
        if let time = shipment.logisticsTime { lines.append("物流发生时间：\(ShipmentDateDisplay.string(time))") }
        lines.append("上次成功：" + (shipment.lastQueriedAt.map { ShipmentDateDisplay.string($0) } ?? "尚无成功查询"))
        if let error = shipment.lastRefreshError, !error.isEmpty { lines.append("最近刷新失败：\(error)") }
        return lines.joined(separator: "\n")
    }
    /// A refresh result is followed only by a read, never another charged query.
    static func snapshot(_ service: TrackingRefreshService, id: UUID, number: String) throws -> Shipment {
        guard let shipment = try service.store.snapshot().shipments.first(where: { $0.id == id }) else {
            throw PickupStorageError.notFound
        }
        guard CarrierDetector.sanitize(shipment.trackingNumber) == number else { throw PickupStorageError.stalePreview }
        return shipment
    }
}

struct RefreshPendingShipmentsIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新未签收快递物流"
    static var description = IntentDescription("按来源及本票默认设置刷新未签收快递。可选仅商城（不使用付费接口）或强制UAPI／Tmini（付费查询）；失败不会自动切换渠道。")
    @Parameter(title: "查询渠道（可选，默认跟随来源）") var channel: QueryChannelChoice?
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let service = try TrackingRefreshService.live()
        let before = try service.store.snapshot().shipments.filter(TrackingRefreshService.isPending)
        let report = try await service.refreshPending(mode: channel.resolvedMode)
        let after = try service.store.snapshot().shipments
        let details = before.compactMap { previous -> String? in
            guard let current = after.first(where: { $0.id == previous.id }),
                  CarrierDetector.sanitize(current.trackingNumber) == CarrierDetector.sanitize(previous.trackingNumber) else { return nil }
            return ShipmentRefreshPresentation.details(current)
        }
        let message = ([report.message, "以下为刷新后的只读快照；未处理或失败票保留上次成功数据。"] + details).joined(separator: "\n\n")
        return .result(value: message, dialog: "\(message)")
    }
}

struct RefreshShipmentIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新指定快递物流"
    static var description = IntentDescription("按单号刷新App中已有记录，不新增记录。默认跟随来源及本票设置；仅商城不使用付费接口，强制UAPI／Tmini可能计费，失败不自动切换渠道。手机尾号仅用于UAPI，留空复用本票已保存值；Tmini不读取尾号。")
    @Parameter(title: "快递单号") var trackingNumber: String
    @Parameter(title: "收件人手机尾号（可选）") var phone: String?
    @Parameter(title: "查询渠道（可选，默认跟随来源）") var channel: QueryChannelChoice?
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let service = try TrackingRefreshService.live()
        let number = try ShipmentShortcutParser.number(trackingNumber)
        let matches = try service.store.snapshot().shipments.filter { CarrierDetector.sanitize($0.trackingNumber) == number }
        guard matches.count == 1, let previous = matches.first else {
            if matches.isEmpty { throw PickupStorageError.notFound }
            throw ShipmentShortcutError.ambiguous
        }
        var isCached = false
        let completed = try await service.refresh(id: previous.id, phone: phone,
            expectedTrackingNumber: number, mode: channel.resolvedMode, cacheFeedback: { isCached = $0 })
        let latest = try ShipmentRefreshPresentation.snapshot(service, id: previous.id, number: number)
        let message = ShipmentRefreshPresentation.result(latest, newlyDelivered: completed, isCached: isCached)
        return .result(value: message, dialog: "\(message)")
    }
}
