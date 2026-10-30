import Foundation

struct Shipment: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var trackingNumber: String
    var carrierName: String
    var carrierCode: String
    var status: ShipmentStatus
    var note: String
    var pickupCode: String
    var createdAt: Date
    var updatedAt: Date
    var lastCheckedAt: Date?
    var reminderDate: Date?
    // Optional fields keep old shipment JSON and backups decodable.
    var logisticsInfo: String?
    var logisticsTime: Date?

    init(
        id: UUID = UUID(),
        trackingNumber: String,
        carrierName: String,
        carrierCode: String,
        status: ShipmentStatus = .inTransit,
        note: String = "",
        pickupCode: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastCheckedAt: Date? = nil,
        reminderDate: Date? = nil,
        logisticsInfo: String? = nil,
        logisticsTime: Date? = nil
    ) {
        self.id = id
        self.trackingNumber = trackingNumber
        self.carrierName = carrierName
        self.carrierCode = carrierCode
        self.status = status
        self.note = note
        self.pickupCode = pickupCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastCheckedAt = lastCheckedAt
        self.reminderDate = reminderDate
        self.logisticsInfo = logisticsInfo
        self.logisticsTime = logisticsTime
    }
}

enum ShipmentStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case inTransit = "运输中"
    case outForDelivery = "派送中"
    case readyForPickup = "待取件"
    case delivered = "已签收"
    case exception = "异常"
    case archived = "已归档"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .inTransit: return "truck.box"
        case .outForDelivery: return "figure.walk.motion"
        case .readyForPickup: return "shippingbox"
        case .delivered: return "checkmark.seal.fill"
        case .exception: return "exclamationmark.triangle.fill"
        case .archived: return "archivebox.fill"
        }
    }
}
