import AppIntents
import Foundation

/// Uses record identity, not list index or a copied display name.
struct ShipmentChoiceEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "快递")
    static var defaultQuery = ShipmentChoiceQuery()
    let id: UUID
    let trackingNumber: String
    let carrierName: String
    let summary: String
    init(_ shipment: Shipment) {
        id = shipment.id
        trackingNumber = CarrierDetector.sanitize(shipment.trackingNumber)
        carrierName = shipment.carrierName
        summary = shipment.note.isEmpty ? shipment.status.rawValue : shipment.status.rawValue + " · " + shipment.note
    }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(carrierName) · \(trackingNumber)", subtitle: "\(summary)")
    }
    static func choices(in shipments: [Shipment]) -> [ShipmentChoiceEntity] {
        shipments.filter(TrackingRefreshService.isPending).sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }.map(Self.init)
    }
}
struct ShipmentChoiceQuery: EntityStringQuery {
    private func choices() throws -> [ShipmentChoiceEntity] {
        let store = try SharedPickupStore(appGroupID: nil, accessMode: .existingSharedData)
        return ShipmentChoiceEntity.choices(in: try store.snapshot().shipments)
    }
    func entities(for identifiers: [UUID]) async throws -> [ShipmentChoiceEntity] {
        let available = try choices()
        return identifiers.compactMap { id in available.first { $0.id == id } }
    }
    func suggestedEntities() async throws -> [ShipmentChoiceEntity] { try choices() }
    func entities(matching string: String) async throws -> [ShipmentChoiceEntity] {
        let available = try choices()
        guard !string.isEmpty else { return available }
        return available.filter {
            $0.trackingNumber.localizedCaseInsensitiveContains(string) ||
            $0.carrierName.localizedCaseInsensitiveContains(string) ||
            $0.summary.localizedCaseInsensitiveContains(string)
        }
    }
}

struct RefreshSelectedShipmentIntent: AppIntent {
    static var title: LocalizedStringResource = "选择快递并刷新物流"
    static var description = IntentDescription("选择App中已有未签收快递，或将快递参数设为每次询问。默认跟随来源及本票设置；仅商城不使用收费UAPI，强制UAPI可能消耗积分。手机尾号仅用于UAPI，留空复用本票已保存值。")
    @Parameter(title: "快递", requestValueDialog: "请选择要刷新物流的快递") var shipment: ShipmentChoiceEntity
    @Parameter(title: "收件人手机尾号（可选）") var phone: String?
    @Parameter(title: "查询渠道（可选，默认跟随来源）") var channel: QueryChannelChoice?
    static var parameterSummary: some ParameterSummary {
        Summary("刷新\(\.$shipment)的物流") {
            \.$phone
            \.$channel
        }
    }
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let service = try TrackingRefreshService.live()
        var isCached = false
        let completed = try await service.refresh(id: shipment.id, phone: phone,
            expectedTrackingNumber: shipment.trackingNumber, pendingOnly: true, mode: channel.resolvedMode, cacheFeedback: { isCached = $0 })
        let latest = try ShipmentRefreshPresentation.snapshot(service, id: shipment.id, number: shipment.trackingNumber)
        let message = ShipmentRefreshPresentation.result(latest, newlyDelivered: completed, isCached: isCached)
        return .result(value: message, dialog: "\(message)")
    }
}
