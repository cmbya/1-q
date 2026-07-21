import Foundation

struct TrackingEvent: Identifiable, Codable, Hashable {
    let id: UUID
    let time: Date
    let description: String
    let location: String?

    init(id: UUID = UUID(), time: Date, description: String, location: String? = nil) {
        self.id = id
        self.time = time
        self.description = description
        self.location = location
    }
}

struct TrackingSnapshot: Codable, Hashable {
    let status: ShipmentStatus
    let events: [TrackingEvent]
    let checkedAt: Date
}

protocol TrackingProvider {
    func query(trackingNumber: String, carrierCode: String) async throws -> TrackingSnapshot
}

enum TrackingProviderError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未配置实时物流查询服务。"
        }
    }
}

struct UnavailableTrackingProvider: TrackingProvider {
    func query(trackingNumber: String, carrierCode: String) async throws -> TrackingSnapshot {
        throw TrackingProviderError.notConfigured
    }
}
