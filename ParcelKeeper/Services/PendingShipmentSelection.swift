import Foundation

/// Presentation preference only; no network calls or shipment mutations.
enum PendingShipmentSelection {
    struct Identity: Equatable {
        let selectedID: UUID?
        let browsing: Bool
    }
    static func identity(in data: PickupDataset) -> Identity {
        Identity(selectedID: selected(in: data)?.id, browsing: isBrowsing(in: data))
    }
    static let kind = "PendingShipmentWidget"
    static func isBrowsing(in data: PickupDataset) -> Bool {
        guard let id = data.pendingShipmentBrowsingID else { return false }
        return eligible(data.shipments).contains { $0.id == id }
    }
    static func normalizeBrowsing(in data: inout PickupDataset) {
        if !isBrowsing(in: data) { data.pendingShipmentBrowsingID = nil }
    }
    static func eligible(_ shipments: [Shipment]) -> [Shipment] {
        shipments.filter { ($0.status != .delivered || $0.needsReceiptConfirmation) && $0.status != .archived }.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
    }
    static func selected(in data: PickupDataset) -> Shipment? {
        let candidates = eligible(data.shipments)
        return candidates.first(where: { $0.id == data.pendingShipmentBrowsingID }) ?? candidates.first
    }
}

extension SharedPickupStore {
    func browsePendingShipment(direction: Int, expectedID: UUID?) throws {
        guard direction == -1 || direction == 1 else { throw PickupStorageError.invalidData("切换方向无效") }
        try transaction { data in
            let candidates = PendingShipmentSelection.eligible(data.shipments)
            let current = PendingShipmentSelection.selected(in: data)
            guard current?.id == expectedID else { throw PickupStorageError.staleCompletion }
            guard candidates.count > 1, let current,
                  let index = candidates.firstIndex(where: { $0.id == current.id }) else { return }
            let next = (index + direction + candidates.count) % candidates.count
            data.pendingShipmentBrowsingID = candidates[next].id
        }
    }
    func resetPendingShipmentBrowsing(expected: PendingShipmentSelection.Identity? = nil) throws {
        try transaction { data in
            // Missing parameters from an older widget must not clear newer preferences.
            guard let expected, PendingShipmentSelection.identity(in: data) == expected else {
                throw PickupStorageError.staleCompletion
            }
            data.pendingShipmentBrowsingID = nil
        }
    }
}
