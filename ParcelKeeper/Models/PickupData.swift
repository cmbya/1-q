import Foundation

struct PickupGroup: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var sortOrder: Int
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

struct PickupRecord: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var groupID: UUID
    var code: String
    var location: String = ""
    var source: String = ""
    var isCompleted: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    // The shipment remains authoritative for its original logistics and reminder fields.
    var shipmentID: UUID? = nil
    // nil follows automatic completion; explicit user completion/reopen wins.
    // Optional for datasets/backups written before backend pickup synchronization.
    var completionOverride: Bool? = nil
}

// Orders without a waybill never enter tracking queries.
struct BackendPendingOrder: Codable, Equatable, Identifiable {
    var origin: String
    var accountID: String
    var orderID: String
    var platform: String
    var platformOrderID: String
    var title: String
    var awaitingShipment: Bool
    var id: String { [origin, accountID, orderID].joined(separator: "|") }
    var statusText: String { awaitingShipment ? "待发货 · 暂无运单号" : "暂无运单号" }
}

struct PickupDataset: Codable, Equatable {
    static let currentVersion = 1
    var version: Int = currentVersion
    var groups: [PickupGroup]
    var records: [PickupRecord]
    var shipments: [Shipment]
    // Stable default for legacy shipment creation, independent of group name.
    var expressGroupID: UUID? = nil
    // Optional so pre-train datasets and memberwise initializers remain compatible.
    var trainTickets: [TrainTicket]? = nil
    var trainWidgetBindings: [TrainWidgetBinding]? = nil
    // Optional preference: missing/stale IDs fall back to the first pending ticket.
    var pendingShipmentBrowsingID: UUID? = nil
    var backendPendingOrders: [BackendPendingOrder]? = nil

    func pickupCodeActive(_ record: PickupRecord) -> Bool {
        guard let id = record.shipmentID else { return true }
        return shipments.first(where: { $0.id == id })?.isPickupCodeActive ?? true
    }
}

struct BackupPreview {
    let incoming: PickupDataset
    let conflictingGroupIDs: [UUID]
    let conflictingRecordIDs: [UUID]
    let conflictingShipmentIDs: [UUID]
    let conflictingTrackingNumbers: [String]
    var conflictingPendingOrderIDs: [String] = []
    var conflictingTrainTicketIDs: [UUID] = []
    var conflictingTrainWidgetSlots: [TrainWidgetSlot] = []
    // Detect any concurrent change between preview and confirmation.
    let baseData: Data
    var hasConflicts: Bool {
        !conflictingPendingOrderIDs.isEmpty || !conflictingGroupIDs.isEmpty || !conflictingRecordIDs.isEmpty || !conflictingShipmentIDs.isEmpty || !conflictingTrackingNumbers.isEmpty || !conflictingTrainTicketIDs.isEmpty || !conflictingTrainWidgetSlots.isEmpty
    }
}

enum BackupConflictPolicy { case keepExisting, replaceExisting }
