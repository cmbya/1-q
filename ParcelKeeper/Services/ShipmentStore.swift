import Foundation
import WidgetKit

@MainActor
final class ShipmentStore: ObservableObject {
    @Published private(set) var shipments: [Shipment] = []
    @Published private(set) var groups: [PickupGroup] = []
    @Published private(set) var pickupRecords: [PickupRecord] = []
    @Published var lastErrorMessage: String?
    @Published private(set) var reminderOperationInProgress = false
    func beginReminderOperation() -> Bool {
        guard !reminderOperationInProgress else { return false }
        reminderOperationInProgress = true
        return true
    }
    func endReminderOperation() { reminderOperationInProgress = false }
    private var storage: SharedPickupStore?
    var isHistoricalSnapshot: Bool { storage?.isReadOnly == true }

    // Configure ParcelKeeperAppGroup in Info.plist and matching entitlements for every target.
    init(fileManager: FileManager = .default, appGroupID: String? = Bundle.main.object(forInfoDictionaryKey: "ParcelKeeperAppGroup") as? String) {
        do {
            storage = try SharedPickupStore(appGroupID: appGroupID, fileManager: fileManager)
            try reload()
        } catch PickupStorageError.appGroupUnavailable {
            // Show existing local data without creating or migrating anything.
            if let local = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
               let fallback = try? SharedPickupStore(appGroupID: nil, fileManager: fileManager, containerURL: local, readOnly: true) {
                storage = fallback
                if let data = try? fallback.snapshot() { apply(data) }
            }
            lastErrorMessage = PickupStorageError.appGroupUnavailable.localizedDescription + " 显示的本地内容仅为可能过时的历史快照，不代表当前共享数据，且只读。"
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
    // Call when the application returns to the foreground.
    func refreshOnForeground() {
        do { try reload() } catch { lastErrorMessage = error.localizedDescription }
    }
    func reload() throws {
        guard let storage = storage else { throw PickupStorageError.appGroupUnavailable }
        apply(try storage.snapshot())
        lastErrorMessage = storage.isReadOnly ? PickupStorageError.appGroupUnavailable.localizedDescription + " 显示的本地内容仅为可能过时的历史快照，不代表当前共享数据，且只读。" : nil
    }
    private func apply(_ data: PickupDataset) {
        shipments = data.shipments.sorted {
            if ($0.status == .archived) != ($1.status == .archived) { return $0.status != .archived }
            return $0.updatedAt > $1.updatedAt
        }
        groups = data.groups.sorted { $0.sortOrder < $1.sortOrder }
        pickupRecords = data.records
    }
    @discardableResult private func change<T>(_ action: (inout PickupDataset) throws -> T) throws -> T {
        guard let storage = storage else { throw PickupStorageError.appGroupUnavailable }
        let (result, committed) = try storage.transaction { data in
            let result = try action(&data)
            return (result, data)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "ParcelKeeperPickupWidget")
        // Preserve the committed snapshot even if a subsequent read fails.
        do { try reload() } catch {
            apply(committed)
            lastErrorMessage = "数据已保存，但刷新失败：\(error.localizedDescription)"
        }
        return result
    }
    private func perform(_ action: (inout PickupDataset) throws -> Void) {
        do { try change(action) } catch { lastErrorMessage = error.localizedDescription }
    }
    var activeShipments: [Shipment] { shipments.filter { $0.status != .archived } }
    func shipment(id: UUID) -> Shipment? { shipments.first { $0.id == id } }
    func contains(trackingNumber: String) -> Bool {
        let number = CarrierDetector.sanitize(trackingNumber)
        return shipments.contains { CarrierDetector.sanitize($0.trackingNumber) == number }
    }
    enum ShipmentWriteError: LocalizedError {
        case duplicateTrackingNumber
        var errorDescription: String? { "运单号已存在" }
    }
    func addThrowing(_ shipment: Shipment) throws {
            try change { data in
                guard !data.shipments.contains(where: { CarrierDetector.sanitize($0.trackingNumber) == CarrierDetector.sanitize(shipment.trackingNumber) }) else { throw ShipmentWriteError.duplicateTrackingNumber }
                data.shipments.insert(shipment, at: 0)
                guard let groupID = data.expressGroupID, data.groups.contains(where: { $0.id == groupID }) else { throw PickupStorageError.invalidData("快递默认分组不可用") }
                data.records.append(PickupRecord(groupID: groupID, code: shipment.pickupCode, source: shipment.note, createdAt: shipment.createdAt, updatedAt: shipment.updatedAt, shipmentID: shipment.id))
            }
    }
    @discardableResult func add(_ shipment: Shipment) -> Bool {
        do { try addThrowing(shipment); return true }
        catch { lastErrorMessage = error.localizedDescription; return false }
    }
    func deleteThrowing(id: UUID) throws {
        try change { d in
            guard d.shipments.contains(where: { $0.id == id }) else { throw PickupStorageError.notFound }
            d.shipments.removeAll { $0.id == id }; d.records.removeAll { $0.shipmentID == id }
        }
    }
    func delete(id: UUID) { do { try deleteThrowing(id: id) } catch { lastErrorMessage = error.localizedDescription } }
    func delete(at offsets: IndexSet, in filteredShipments: [Shipment]) {
        let ids = Set(offsets.map { filteredShipments[$0].id })
        perform { d in d.shipments.removeAll { ids.contains($0.id) }; d.records.removeAll { $0.shipmentID.map { ids.contains($0) } ?? false } }
    }
    private func updateThrowing(id: UUID, mutation: (inout Shipment) -> Void) throws {
        try change { data in
            guard let index = data.shipments.firstIndex(where: { $0.id == id }) else { throw PickupStorageError.notFound }
            mutation(&data.shipments[index])
            let shipment = data.shipments[index]
            if let recordIndex = data.records.firstIndex(where: { $0.shipmentID == id }) {
                data.records[recordIndex].code = shipment.pickupCode
                data.records[recordIndex].source = shipment.note
                data.records[recordIndex].updatedAt = shipment.updatedAt
            } else {
                guard let groupID = data.expressGroupID, data.groups.contains(where: { $0.id == groupID }) else { throw PickupStorageError.invalidData("快递默认分组不可用") }
                data.records.append(PickupRecord(groupID: groupID, code: shipment.pickupCode, source: shipment.note, createdAt: shipment.createdAt, updatedAt: shipment.updatedAt, shipmentID: id))
            }
        }
    }
    private func update(id: UUID, mutation: (inout Shipment) -> Void) {
        do { try updateThrowing(id: id, mutation: mutation) } catch { lastErrorMessage = error.localizedDescription }
    }
    func updateStatus(id: UUID, status: ShipmentStatus) { update(id: id) { $0.status = status; $0.updatedAt = Date() } }
    func updateNote(id: UUID, note: String) { update(id: id) { $0.note = note; $0.updatedAt = Date() } }
    func updatePickupCode(id: UUID, pickupCode: String) { update(id: id) { $0.pickupCode = pickupCode; $0.updatedAt = Date() } }
    func updateCarrier(id: UUID, carrier: CarrierOption) { update(id: id) { $0.carrierName = carrier.name; $0.carrierCode = carrier.code; $0.updatedAt = Date() } }
    func markChecked(id: UUID) { update(id: id) { $0.lastCheckedAt = Date(); $0.updatedAt = Date() } }
    func updateReminderThrowing(id: UUID, date: Date?) throws { try updateThrowing(id: id) { $0.reminderDate = date; $0.updatedAt = Date() } }

    @discardableResult func createGroup(name: String) throws -> UUID {
        let group = PickupGroup(name: name, sortOrder: (groups.map(\.sortOrder).max() ?? -1) + 1)
        try change { $0.groups.append(group) }; return group.id
    }
    func renameGroup(id: UUID, name: String) throws { try change { d in
        guard let i = d.groups.firstIndex(where: { $0.id == id }) else { throw PickupStorageError.notFound }
        d.groups[i].name = name; d.groups[i].updatedAt = Date()
    } }
    func reorderGroups(ids: [UUID]) throws { try change { d in
        guard ids.count == d.groups.count, Set(ids) == Set(d.groups.map(\.id)) else { throw PickupStorageError.invalidData("分组排序不完整") }
        for (order, id) in ids.enumerated() { if let i = d.groups.firstIndex(where: { $0.id == id }) { d.groups[i].sortOrder = order; d.groups[i].updatedAt = Date() } }
    } }
    func deleteGroup(id: UUID, moveTo destination: UUID? = nil) throws { try change { d in
        guard d.groups.contains(where: { $0.id == id }) else { throw PickupStorageError.notFound }
        guard d.groups.count > 1 else { throw PickupStorageError.invalidData("至少保留一个分组") }
        if d.records.contains(where: { $0.groupID == id }) || d.expressGroupID == id {
            guard let destination = destination, destination != id, d.groups.contains(where: { $0.id == destination }) else { throw PickupStorageError.nonEmptyGroup }
            for i in d.records.indices where d.records[i].groupID == id { d.records[i].groupID = destination; d.records[i].updatedAt = Date() }
        }
        if d.expressGroupID == id { d.expressGroupID = destination }
        d.groups.removeAll { $0.id == id }
    } }
    @discardableResult func addPickupRecord(groupID: UUID, code: String, location: String = "", source: String = "") throws -> UUID {
        let record = PickupRecord(groupID: groupID, code: code, location: location, source: source)
        try change { data in
            guard !data.records.contains(where: {
                $0.groupID == groupID && !$0.isCompleted && $0.code.trimmingCharacters(in: .whitespacesAndNewlines) == code.trimmingCharacters(in: .whitespacesAndNewlines)
            }) else { throw PickupStorageError.invalidData("此分组已有未完成的相同取码，未重复添加。") }
            data.records.append(record)
        }; return record.id
    }
    func deletePickupRecord(id: UUID) throws {
        try change { data in
            guard let record = data.records.first(where: { $0.id == id }) else { throw PickupStorageError.notFound }
            guard record.shipmentID == nil else { throw PickupStorageError.invalidData("关联快递请从快递页面删除，以保留数据一致性。") }
            data.records.removeAll { $0.id == id }
        }
    }
    func updatePickupRecord(id: UUID, code: String, location: String, source: String) throws { try change { d in
        guard let i = d.records.firstIndex(where: { $0.id == id }) else { throw PickupStorageError.notFound }
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PickupStorageError.invalidData("取码不能为空") }
        let now = Date()
        d.records[i].code = code; d.records[i].location = location; d.records[i].source = source; d.records[i].updatedAt = now
        if let shipmentID = d.records[i].shipmentID, let j = d.shipments.firstIndex(where: { $0.id == shipmentID }) {
            d.shipments[j].pickupCode = code; d.shipments[j].note = source; d.shipments[j].updatedAt = now
        }
    } }
    func movePickupRecord(id: UUID, to groupID: UUID) throws { try change { d in
        guard d.groups.contains(where: { $0.id == groupID }), let i = d.records.firstIndex(where: { $0.id == id }) else { throw PickupStorageError.notFound }
        d.records[i].groupID = groupID; d.records[i].updatedAt = Date()
    } }
    func setPickupCompleted(id: UUID, completed: Bool) throws { try change { d in
        guard let i = d.records.firstIndex(where: { $0.id == id }) else { throw PickupStorageError.notFound }
        d.records[i].isCompleted = completed; d.records[i].updatedAt = Date()
    } }
    func pendingPickupRecords(groupID: UUID) -> [PickupRecord] { pickupRecords.filter { $0.groupID == groupID && !$0.isCompleted && !$0.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    func makeBackupFile() -> URL? {
        do {
            guard let storage = storage else { throw PickupStorageError.appGroupUnavailable }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("快递管家备份-\(UUID().uuidString).json")
            try storage.exportBackup().write(to: url, options: .atomic); return url
        } catch { lastErrorMessage = error.localizedDescription; return nil }
    }
    func previewBackup(from url: URL) throws -> BackupPreview {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let storage = storage else { throw PickupStorageError.appGroupUnavailable }
        return try storage.previewBackup(Data(contentsOf: url))
    }
    func confirmBackupImport(_ preview: BackupPreview, policy: BackupConflictPolicy? = nil) throws {
        guard let storage = storage else { throw PickupStorageError.appGroupUnavailable }
        let committed = try storage.importBackup(preview, policy: policy)
        WidgetCenter.shared.reloadTimelines(ofKind: "ParcelKeeperPickupWidget")
        do { try reload() } catch {
            apply(committed)
            lastErrorMessage = "备份已导入，但刷新失败：\(error.localizedDescription)"
        }
    }
    // The old UI cannot confirm a preview; never silently import through it.
    func importBackup(from url: URL) -> Bool {
        lastErrorMessage = "请先预览备份并确认导入；当前界面尚未提供确认操作。"
        return false
    }
}
