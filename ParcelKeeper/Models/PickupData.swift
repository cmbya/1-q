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
}

struct PickupDataset: Codable, Equatable {
    static let currentVersion = 1
    var version: Int = currentVersion
    var groups: [PickupGroup]
    var records: [PickupRecord]
    var shipments: [Shipment]
    // Stable default for legacy shipment creation, independent of group name.
    var expressGroupID: UUID? = nil
}

struct BackupPreview {
    let incoming: PickupDataset
    let conflictingGroupIDs: [UUID]
    let conflictingRecordIDs: [UUID]
    let conflictingShipmentIDs: [UUID]
    let conflictingTrackingNumbers: [String]
    // Detect any concurrent change between preview and confirmation.
    let baseData: Data
    var hasConflicts: Bool {
        !conflictingGroupIDs.isEmpty || !conflictingRecordIDs.isEmpty || !conflictingShipmentIDs.isEmpty || !conflictingTrackingNumbers.isEmpty
    }
}

enum BackupConflictPolicy { case keepExisting, replaceExisting }
