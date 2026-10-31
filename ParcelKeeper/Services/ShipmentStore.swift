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
    init(fileManager: FileManager = .default, appGroupID: String? = Bundle.main.object(forInfoDictionaryKey: "ParcelKeeperAppGroup") as? String,
         storageProvider: (() throws -> SharedPickupStore)? = nil, historicalContainerURL: URL? = nil) {
        do {
            if let storageProvider {
                storage = try storageProvider()
            } else {
                storage = try SharedPickupStore(appGroupID: appGroupID, fileManager: fileManager)
            }
            try reload()
        } catch {
            // Only lack of access permits historical fallback. Choosing a group or
            // resolving competing datasets must never silently select local data.
            let permitsHistory: Bool
            switch error {
            case PickupStorageError.appGroupUnavailable, AppGroupResolver.ResolutionError.noAccess:
                permitsHistory = true
            default:
                permitsHistory = false
            }
            // Preserve an established connection after a transient dataset-lock timeout.
            // No historical fallback is permitted for this case; reload can retry it.
            if !((error as? POSIXError)?.code == .ETIMEDOUT && storage != nil) {
                storage = nil
            }
            if permitsHistory {
                let local = historicalContainerURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                if let local,
                   let fallback = try? SharedPickupStore(appGroupID: nil, fileManager: fileManager, legacyURL: local.appendingPathComponent("ParcelKeeper/shipments.json"), containerURL: local, readOnly: true),
                   let data = try? fallback.snapshot() {
                    storage = fallback
                    apply(data)
                }
                lastErrorMessage = error.localizedDescription + " 显示的本地内容仅为可能过时的历史快照，不代表当前共享数据，且只读。"
            } else {
                lastErrorMessage = error.localizedDescription
            }
        }
    }
    func reconnectSharedStorage() throws {
        let next = try SharedPickupStore(appGroupID: nil)
        let data = try next.snapshot()
        storage = next
        apply(data)
        lastErrorMessage = nil
        WidgetCenter.shared.reloadAllTimelines()
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
        for slot in WidgetSlot.allCases { WidgetCenter.shared.reloadTimelines(ofKind: slot.kind) }
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
    // Only newly introduced pending identities are checked, under the storage lock.
    // Existing history/backup duplicates must not block unrelated edits.
    private func checkPendingDuplicate(_ record: PickupRecord, previous: PickupRecord? = nil, in data: PickupDataset) throws {
        let code = record.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !record.isCompleted, !code.isEmpty else { return }
        if let previous, !previous.isCompleted, previous.groupID == record.groupID,
           previous.code.trimmingCharacters(in: .whitespacesAndNewlines) == code { return }
        guard !data.records.contains(where: {
            $0.id != record.id && $0.groupID == record.groupID && !$0.isCompleted &&
            $0.code.trimmingCharacters(in: .whitespacesAndNewlines) == code
        }) else { throw PickupStorageError.invalidData("此分组已有未完成的相同取码。") }
    }

    func addThrowing(_ shipment: Shipment) throws {
            try change { data in
                guard !data.shipments.contains(where: { CarrierDetector.sanitize($0.trackingNumber) == CarrierDetector.sanitize(shipment.trackingNumber) }) else { throw ShipmentWriteError.duplicateTrackingNumber }
                data.shipments.insert(shipment, at: 0)
                guard let groupID = data.expressGroupID, data.groups.contains(where: { $0.id == groupID }) else { throw PickupStorageError.invalidData("快递默认分组不可用") }
                let record = PickupRecord(groupID: groupID, code: shipment.pickupCode, source: shipment.note, isCompleted: shipment.status == .delivered || shipment.status == .archived, createdAt: shipment.createdAt, updatedAt: shipment.updatedAt, shipmentID: shipment.id)
                try checkPendingDuplicate(record, in: data)
                data.records.append(record)
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
            let previousStatus = data.shipments[index].status
            mutation(&data.shipments[index])
            let shipment = data.shipments[index]
            if let recordIndex = data.records.firstIndex(where: { $0.shipmentID == id }) {
                let previous = data.records[recordIndex]
                data.records[recordIndex].code = shipment.pickupCode
                data.records[recordIndex].source = shipment.note
                // Only an actual logistics status change synchronizes completion.
                // Editing a note/reminder must preserve an explicit pickup restore.
                if previousStatus != shipment.status {
                    data.records[recordIndex].isCompleted = shipment.status == .delivered || shipment.status == .archived
                }
                data.records[recordIndex].updatedAt = shipment.updatedAt
                try checkPendingDuplicate(data.records[recordIndex], previous: previous, in: data)
            } else {
                guard let groupID = data.expressGroupID, data.groups.contains(where: { $0.id == groupID }) else { throw PickupStorageError.invalidData("快递默认分组不可用") }
                let record = PickupRecord(groupID: groupID, code: shipment.pickupCode, source: shipment.note, isCompleted: shipment.status == .delivered || shipment.status == .archived, createdAt: shipment.createdAt, updatedAt: shipment.updatedAt, shipmentID: id)
                try checkPendingDuplicate(record, in: data)
                data.records.append(record)
            }
        }
    }
    private func reportWriteError(_ action: () throws -> Void) {
        do { try action() } catch { lastErrorMessage = error.localizedDescription }
    }
    func updateStatusThrowing(id: UUID, status: ShipmentStatus) throws {
        try updateThrowing(id: id) { $0.status = status; $0.updatedAt = Date() }
    }
    func updateStatus(id: UUID, status: ShipmentStatus) {
        reportWriteError { try updateStatusThrowing(id: id, status: status) }
    }
    func updateNoteThrowing(id: UUID, note: String) throws {
        try updateThrowing(id: id) { $0.note = note; $0.updatedAt = Date() }
    }
    func updateNote(id: UUID, note: String) {
        reportWriteError { try updateNoteThrowing(id: id, note: note) }
    }
    func updatePickupCodeThrowing(id: UUID, pickupCode: String) throws {
        try updateThrowing(id: id) { $0.pickupCode = pickupCode; $0.updatedAt = Date() }
    }
    func updatePickupCode(id: UUID, pickupCode: String) {
        reportWriteError { try updatePickupCodeThrowing(id: id, pickupCode: pickupCode) }
    }
    func updateCarrierThrowing(id: UUID, carrier: CarrierOption) throws {
        try updateThrowing(id: id) {
            $0.updateCarrierSelection(name: carrier.name, code: carrier.code)
            $0.updatedAt = Date()
        }
    }
    func updateCarrier(id: UUID, carrier: CarrierOption) {
        reportWriteError { try updateCarrierThrowing(id: id, carrier: carrier) }
    }
    func markCheckedThrowing(id: UUID) throws {
        try updateThrowing(id: id) { $0.lastCheckedAt = Date(); $0.updatedAt = Date() }
    }
    func markChecked(id: UUID) { reportWriteError { try markCheckedThrowing(id: id) } }
    func updateReminderThrowing(id: UUID, date: Date?) throws { try updateThrowing(id: id) { $0.reminderDate = date; $0.updatedAt = Date() } }

    @discardableResult func createGroup(name: String) throws -> UUID {
        try change { data in
            // Derive the append position from the locked dataset, never this store's cache.
            var maximum = data.groups.map(\.sortOrder).max() ?? -1
            if maximum == Int.max {
                // Imported orders can exhaust Int. Compact only then, preserving business
                // order (and stored array order for ties), identities, dates and links.
                let indices = data.groups.indices.sorted {
                    let lhs = data.groups[$0].sortOrder, rhs = data.groups[$1].sortOrder
                    return lhs == rhs ? $0 < $1 : lhs < rhs
                }
                for (order, index) in indices.enumerated() { data.groups[index].sortOrder = order }
                maximum = data.groups.count - 1
            }
            let group = PickupGroup(name: name, sortOrder: maximum + 1)
            data.groups.append(group)
            return group.id
        }
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
            let previous = d.records
            for i in d.records.indices where d.records[i].groupID == id { d.records[i].groupID = destination; d.records[i].updatedAt = Date() }
            for record in d.records where previous.contains(where: { $0.id == record.id && $0.groupID == id }) {
                try checkPendingDuplicate(record, previous: previous.first { $0.id == record.id }, in: d)
            }
        }
        if d.expressGroupID == id { d.expressGroupID = destination }
        d.groups.removeAll { $0.id == id }
    } }
    @discardableResult func addPickupRecord(groupID: UUID, code: String, location: String = "", source: String = "") throws -> UUID {
        let record = PickupRecord(groupID: groupID, code: code, location: location, source: source)
        try change { data in
            try checkPendingDuplicate(record, in: data)
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
    func updatePickupRecord(id: UUID, code: String? = nil, location: String? = nil, source: String? = nil, expected: PickupRecord? = nil) throws { try change { d in
        guard let i = d.records.firstIndex(where: { $0.id == id }) else { throw PickupStorageError.notFound }
        let latest = d.records[i]
        if let expected {
            guard expected.id == id else { throw PickupStorageError.invalidData("编辑快照与记录不匹配") }
        }
        // With a snapshot, full-form callers also behave as a field-level patch.
        let changesCode = code.map { value in expected.map { value != $0.code } ?? true } ?? false
        let changesLocation = location.map { value in expected.map { value != $0.location } ?? true } ?? false
        let changesSource = source.map { value in expected.map { value != $0.source } ?? true } ?? false
        if let expected {
            guard (!changesCode || latest.code == expected.code),
                  (!changesLocation || latest.location == expected.location),
                  (!changesSource || latest.source == expected.source) else {
                throw PickupStorageError.invalidData("此字段已被其他操作修改，请重新打开后编辑。")
            }
        }
        guard changesCode || changesLocation || changesSource else { return }
        if changesCode, let code {
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PickupStorageError.invalidData("取码不能为空") }
            d.records[i].code = code
        }
        if changesLocation, let location { d.records[i].location = location }
        if changesSource, let source { d.records[i].source = source }
        try checkPendingDuplicate(d.records[i], previous: latest, in: d)
        let now = Date()
        d.records[i].updatedAt = now
        if (changesCode || changesSource), let shipmentID = latest.shipmentID, let j = d.shipments.firstIndex(where: { $0.id == shipmentID }) {
            if changesCode { d.shipments[j].pickupCode = d.records[i].code }
            if changesSource { d.shipments[j].note = d.records[i].source }
            d.shipments[j].updatedAt = now
        }
    } }
    func movePickupRecord(id: UUID, to groupID: UUID) throws { try change { d in
        guard d.groups.contains(where: { $0.id == groupID }), let i = d.records.firstIndex(where: { $0.id == id }) else { throw PickupStorageError.notFound }
        let previous = d.records[i]
        d.records[i].groupID = groupID; d.records[i].updatedAt = Date()
        try checkPendingDuplicate(d.records[i], previous: previous, in: d)
    } }
    func setPickupCompleted(id: UUID, completed: Bool) throws { try change { d in
        guard let i = d.records.firstIndex(where: { $0.id == id }) else { throw PickupStorageError.notFound }
        let previous = d.records[i]
        d.records[i].isCompleted = completed; d.records[i].updatedAt = Date()
        try checkPendingDuplicate(d.records[i], previous: previous, in: d)
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
        for slot in WidgetSlot.allCases { WidgetCenter.shared.reloadTimelines(ofKind: slot.kind) }
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
