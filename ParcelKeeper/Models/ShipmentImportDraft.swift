import Foundation

struct ShipmentImportDraft: Identifiable, Sendable {
    let id: UUID
    var trackingNumber: String
    var carrier: CarrierOption
    var confidence: Double
    var status: ShipmentStatus
    var note: String
    var pickupCode: String
    var isSelected: Bool
    var logisticsInfo: String?
    var logisticsTime: Date?
    var queryInfo: String?

    init(
        id: UUID = UUID(),
        trackingNumber: String,
        carrier: CarrierOption,
        confidence: Double,
        status: ShipmentStatus = .inTransit,
        note: String = "",
        pickupCode: String = "",
        isSelected: Bool = true,
        logisticsInfo: String? = nil,
        logisticsTime: Date? = nil,
        queryInfo: String? = nil
    ) {
        self.id = id
        self.trackingNumber = trackingNumber
        self.carrier = carrier
        self.confidence = confidence
        self.status = status
        self.note = note
        self.pickupCode = pickupCode
        self.isSelected = isSelected
        self.logisticsInfo = logisticsInfo
        self.logisticsTime = logisticsTime
        self.queryInfo = queryInfo
    }
}
