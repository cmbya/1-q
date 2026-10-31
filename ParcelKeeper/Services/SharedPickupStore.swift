import Foundation
import Darwin
import CryptoKit

enum PickupStorageError: LocalizedError {
    case appGroupUnavailable, requiresMainApp, invalidData(String), notFound, nonEmptyGroup, stalePreview, staleCompletion, conflictConfirmationRequired, queryInProgress
    var errorDescription: String? {
        switch self {
        case .queryInProgress: return "这票快递正在查询，请等待本次查询结束，未重复发送请求。"
        case .requiresMainApp: return "请先打开主 App，完成共享数据初始化。"
        case .appGroupUnavailable: return "无法访问共享容器，未修改原有数据。主 App 与小组件的签名均须授权应用 Info.plist 中 ParcelKeeperAppGroup 指定的组（原始构建为 group.com.dinghao.ParcelKeeper）；证书列有其他应用组不代表授权了此组。请核对重签后的组 ID、描述文件与扩展签名，勿卸载或清空数据。"
        case .invalidData(let message): return "数据无效：\(message)"
        case .notFound: return "记录或分组不存在。"
        case .nonEmptyGroup: return "分组非空，请先选择迁移目标。"
        case .stalePreview: return "数据已变化，请重新预览导入。"
        case .staleCompletion: return "记录已变化或组件已过期，请刷新组件后重试。"
        case .conflictConfirmationRequired: return "备份存在冲突，请预览并选择冲突处理方式。"
        }
    }
}

// All processes must use this service and the same App Group and lock file.
final class SharedPickupStore {
    enum AccessMode {
        case appManaged
        case existingSharedData
    }

    private let accessMode: AccessMode
    private let directory: URL
    private let legacyURL: URL
    private let fileManager: FileManager
    private let readOnly: Bool
    var isReadOnly: Bool { readOnly }
    private let encoder: JSONEncoder = {
        let value = JSONEncoder(); value.dateEncodingStrategy = .deferredToDate
        value.outputFormatting = [.sortedKeys]; return value
    }()
    private let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: number) }
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw PickupStorageError.invalidData("日期格式错误") }
            return date
        }; return value
    }()
    private var dataURL: URL { directory.appendingPathComponent("pickup-data.json") }
    private var lockURL: URL { directory.appendingPathComponent("pickup-data.lock") }

    init(appGroupID: String?, fileManager: FileManager = .default, legacyURL: URL? = nil, containerURL: URL? = nil, readOnly: Bool = false, accessMode: AccessMode = .appManaged) throws {
        self.fileManager = fileManager
        self.accessMode = accessMode
        self.readOnly = readOnly
        let container: URL
        if let injected = containerURL { container = injected }
        else { container = try AppGroupResolver.container(configured: appGroupID) }
        directory = container.appendingPathComponent("ParcelKeeper", isDirectory: true)
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PickupStorageError.invalidData("无法定位旧数据目录")
        }
        self.legacyURL = legacyURL ?? support.appendingPathComponent("ParcelKeeper/shipments.json")
        if !readOnly && accessMode == .appManaged { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    // Separate per-record lock: does not block dataset reads/writes during network awaits.
    final class TrackingQueryLease {
        private var descriptor: Int32?
        private let lock = NSLock()
        fileprivate init(_ fd: Int32) { descriptor = fd }
        func release() {
            lock.lock(); defer { lock.unlock() }
            guard let fd = descriptor else { return }
            descriptor = nil
            flock(fd, LOCK_UN)
            close(fd)
        }
        deinit { release() }
    }
    func acquireTrackingQuery(id: UUID) throws -> TrackingQueryLease {
        guard !readOnly else { throw PickupStorageError.appGroupUnavailable }
        let url = directory.appendingPathComponent("tracking-query-\(id.uuidString).lock")
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { throw PickupStorageError.queryInProgress }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        // Do not unlink: all processes must keep locking the same inode.
        return TrackingQueryLease(fd)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        if readOnly && accessMode == .appManaged { return try body() }
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            if accessMode == .existingSharedData && errno == ENOENT { throw PickupStorageError.requiresMainApp }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        // Use monotonic time: a suspended owner must not hang a widget forever.
        // Timing out never enters the critical section or changes stored data.
        let deadline = ProcessInfo.processInfo.systemUptime + 1.0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw POSIXError(.ETIMEDOUT)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func validate(_ data: PickupDataset) throws {
        guard data.version == PickupDataset.currentVersion else { throw PickupStorageError.invalidData("不支持的备份版本") }
        let groups = Set(data.groups.map(\.id)), records = Set(data.records.map(\.id)), shipments = Set(data.shipments.map(\.id))
        guard !groups.isEmpty, data.expressGroupID.map({ groups.contains($0) }) ?? true, groups.count == data.groups.count, records.count == data.records.count, shipments.count == data.shipments.count,
              data.groups.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              data.records.allSatisfy({ groups.contains($0.groupID) && ($0.shipmentID != nil || !$0.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && ($0.shipmentID == nil || shipments.contains($0.shipmentID!)) }),
              Set(data.records.compactMap(\.shipmentID)).count == data.records.compactMap(\.shipmentID).count else {
            throw PickupStorageError.invalidData("重复 ID、空字段或无效关联")
        }
        let tickets = data.trainTickets ?? []
        let bindings = data.trainWidgetBindings ?? []
        guard Set(tickets.map(\.id)).count == tickets.count,
              Set(bindings.map(\.slot)).count == bindings.count else {
            throw PickupStorageError.invalidData("重复的火车票 ID 或组件槽位")
        }
        // Historical business duplicates are legal; validate structure, not global uniqueness.
        for ticket in tickets { _ = try ticket.fields.validated() }
        // Missing fixed targets deliberately resolve to an empty widget (e.g. old backups).
        for shipment in data.shipments {
            let linked = data.records.filter { $0.shipmentID == shipment.id }
            guard linked.count == 1, linked[0].code == shipment.pickupCode, linked[0].source == shipment.note else {
                throw PickupStorageError.invalidData("运单必须恰有一条关联记录，且取件码和来源一致")
            }
        }
    }

    private func write(_ data: PickupDataset) throws {
        try validate(data)
        let bytes = try encoder.encode(data)
        let decoded = try decoder.decode(PickupDataset.self, from: bytes)
        // Compare all fields, including fractional dates, before and after disk persistence.
        guard decoded == data else { throw PickupStorageError.invalidData("写入前校验失败") }
        let candidate = directory.appendingPathComponent(".pickup-candidate-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: candidate) }
        try bytes.write(to: candidate, options: .atomic)
        let persisted = try decoder.decode(PickupDataset.self, from: Data(contentsOf: candidate))
        try validate(persisted)
        guard persisted == data else { throw PickupStorageError.invalidData("候选文件回读校验失败") }
        guard rename(candidate.path, dataURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func readOrMigrate() throws -> PickupDataset {
        if fileManager.fileExists(atPath: dataURL.path) {
            let data = try decoder.decode(PickupDataset.self, from: Data(contentsOf: dataURL))
            try validate(data); return data
        }
        // This check is inside flock for every shared-data read and transaction.
        guard accessMode == .appManaged else { throw PickupStorageError.requiresMainApp }
        // Read-only historical projections must remain stable across instances.
        // Real migration still generates and persists ordinary UUIDs and dates.
        let now = readOnly ? Date(timeIntervalSinceReferenceDate: 0) : Date()
        let express = PickupGroup(id: readOnly ? historicalID("group:express") : UUID(), name: "快递", sortOrder: 0, createdAt: now, updatedAt: now)
        let food = PickupGroup(id: readOnly ? historicalID("group:food") : UUID(), name: "餐饮", sortOrder: 1, createdAt: now, updatedAt: now)
        var shipments: [Shipment] = []
        if fileManager.fileExists(atPath: legacyURL.path) {
            let bytes = try Data(contentsOf: legacyURL)
            shipments = try decoder.decode([Shipment].self, from: bytes)
            let backup = directory.appendingPathComponent("shipments-legacy-backup.json")
            if !readOnly {
            if fileManager.fileExists(atPath: backup.path) {
                guard try Data(contentsOf: backup) == bytes else { throw PickupStorageError.invalidData("旧数据备份与源文件不同，停止迁移") }
            } else {
                try bytes.write(to: backup, options: .atomic)
                guard try Data(contentsOf: backup) == bytes else { throw PickupStorageError.invalidData("旧数据备份校验失败") }
            }
            }
        }
        let records = shipments.map {
            PickupRecord(id: readOnly ? historicalID("record:\($0.id.uuidString)") : UUID(), groupID: express.id, code: $0.pickupCode, source: $0.note, isCompleted: $0.status == .delivered || $0.status == .archived, createdAt: $0.createdAt, updatedAt: $0.updatedAt, shipmentID: $0.id)
        }
        let result = PickupDataset(groups: [express, food], records: records, shipments: shipments, expressGroupID: express.id)
        try validate(result)
        let check = try decoder.decode(PickupDataset.self, from: encoder.encode(result))
        guard check == result else { throw PickupStorageError.invalidData("迁移校验失败") }
        if !readOnly { try write(result) }
        return result
    }

    private func historicalID(_ key: String) -> UUID {
        // Domain separation and SHA-256 avoid Swift Hasher's process randomization.
        // This source belongs to both app and widget; no extra source membership.
        var bytes = Array(SHA256.hash(data: Data(("ParcelKeeper.history.v1:" + key).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // RFC 9562 custom UUID (version 8)
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func snapshot() throws -> PickupDataset { try locked { try readOrMigrate() } }
    @discardableResult func transaction<T>(_ mutation: (inout PickupDataset) throws -> T) throws -> T {
        guard !readOnly else { throw PickupStorageError.appGroupUnavailable }
        return try locked {
            var data = try readOrMigrate()
            let result = try mutation(&data)
            try write(data)
            return result
        }
    }
    // Compare the displayed snapshot against current data under the same short file lock
    // as the write. Version checking deliberately rejects even note/location-only edits,
    // as well as code changes that were later reverted and completion/reopen cycles.
    // Nil is accepted only to reject legacy intent metadata, never as a bypass/default.
    func completePickup(groupID: UUID, recordID: UUID, expectedCode: String?, expectedUpdatedAt: String?) throws {
        try transaction { data in
            guard let expectedCode = expectedCode,
                  !expectedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let version = expectedUpdatedAt.flatMap({ Double($0) }), version.isFinite else {
                throw PickupStorageError.staleCompletion
            }
            guard data.groups.contains(where: { $0.id == groupID }),
                  let index = data.records.firstIndex(where: { $0.id == recordID && $0.groupID == groupID }) else {
                throw PickupStorageError.notFound
            }
            let current = data.records[index]
            guard !current.isCompleted, current.code == expectedCode,
                  current.updatedAt.timeIntervalSinceReferenceDate == version else {
                throw PickupStorageError.staleCompletion
            }
            data.records[index].isCompleted = true
            data.records[index].updatedAt = Date()
        }
    }

    func exportBackup() throws -> Data { try locked { try encoder.encode(readOrMigrate()) } }
    func previewBackup(_ bytes: Data) throws -> BackupPreview {
        try locked {
            let current = try readOrMigrate()
            let incoming: PickupDataset
            if let legacy = try? decoder.decode([Shipment].self, from: bytes) {
                let express = current.groups.first(where: { $0.id == current.expressGroupID })
                guard let group = express else { throw PickupStorageError.invalidData("没有可用于导入的分组") }
                let records = legacy.map {
                    PickupRecord(id: $0.id, groupID: group.id, code: $0.pickupCode, source: $0.note, isCompleted: $0.status == .delivered || $0.status == .archived, createdAt: $0.createdAt, updatedAt: $0.updatedAt, shipmentID: $0.id)
                }
                incoming = PickupDataset(groups: [group], records: records, shipments: legacy)
            } else { incoming = try decoder.decode(PickupDataset.self, from: bytes) }
            try validate(incoming)
            let numbers = incoming.shipments.map { CarrierDetector.sanitize($0.trackingNumber) }
            // Historical shipments may share a normalized number while retaining distinct IDs.
            // Import resolves matches against the pre-import dataset and rejects ambiguous mappings.
            let conflicts = numbers.filter { number in
                current.shipments.contains { CarrierDetector.sanitize($0.trackingNumber) == number }
            }
            return BackupPreview(incoming: incoming,
                conflictingGroupIDs: incoming.groups.filter { g in current.groups.contains { $0.id == g.id && $0 != g } || current.records.contains { $0.id == g.id } || current.shipments.contains { $0.id == g.id } }.map(\.id),
                conflictingRecordIDs: incoming.records.filter { r in current.records.contains { ($0.id == r.id && $0 != r) || (r.shipmentID != nil && $0.shipmentID == r.shipmentID && $0.id != r.id) } || current.groups.contains { $0.id == r.id } || current.shipments.contains { $0.id == r.id && r.shipmentID != $0.id } }.map(\.id),
                conflictingShipmentIDs: incoming.shipments.filter { s in current.shipments.contains { $0.id == s.id && $0 != s } || current.groups.contains { $0.id == s.id } || current.records.contains { $0.id == s.id && $0.shipmentID != s.id } }.map(\.id),
                conflictingTrackingNumbers: conflicts,
                conflictingTrainTicketIDs: (incoming.trainTickets ?? []).filter { ticket in
                    (current.trainTickets ?? []).contains { $0.id == ticket.id && $0 != ticket }
                }.map(\.id),
                conflictingTrainWidgetSlots: (incoming.trainWidgetBindings ?? []).filter { binding in
                    (current.trainWidgetBindings ?? []).contains { $0.slot == binding.slot && $0 != binding }
                }.map(\.slot),
                baseData: try encoder.encode(current))
        }
    }
    @discardableResult func importBackup(_ preview: BackupPreview, policy: BackupConflictPolicy?) throws -> PickupDataset {
        try transaction { current in
            guard try encoder.encode(current) == preview.baseData else { throw PickupStorageError.stalePreview }
            if preview.hasConflicts && policy == nil { throw PickupStorageError.conflictConfirmationRequired }
            // Cross-entity identifiers are ambiguous and cannot safely be resolved by either policy.
            let incoming = preview.incoming
            guard !incoming.groups.contains(where: { g in current.records.contains { $0.id == g.id } || current.shipments.contains { $0.id == g.id } }),
                  !incoming.records.contains(where: { r in current.groups.contains { $0.id == r.id } || current.shipments.contains { $0.id == r.id && r.shipmentID != $0.id } }),
                  !incoming.shipments.contains(where: { s in current.groups.contains { $0.id == s.id } || current.records.contains { $0.id == s.id && $0.shipmentID != s.id } }) else {
                throw PickupStorageError.invalidData("跨实体 ID 冲突，无法安全合并")
            }
            func merge<T: Identifiable>(_ old: inout [T], _ incoming: [T]) where T.ID == UUID {
                for item in incoming {
                    if let index = old.firstIndex(where: { $0.id == item.id }) {
                        if policy == .replaceExisting { old[index] = item }
                    } else { old.append(item) }
                }
            }
            // Resolve each shipment and its linked record as an indivisible pair.
            // A single incoming shipment may not map to multiple existing shipments, or vice versa.
            var matches: [UUID: UUID] = [:]
            var claimed = Set<UUID>()
            for shipment in incoming.shipments {
                let candidates = current.shipments.filter {
                    $0.id == shipment.id || CarrierDetector.sanitize($0.trackingNumber) == CarrierDetector.sanitize(shipment.trackingNumber)
                }
                guard candidates.count <= 1 else { throw PickupStorageError.invalidData("运单 ID 与运单号发生多重冲突，无法安全合并") }
                if let existing = candidates.first {
                    guard claimed.insert(existing.id).inserted else { throw PickupStorageError.invalidData("多个备份运单匹配同一现有运单，无法安全合并") }
                    matches[shipment.id] = existing.id
                }
            }
            for shipment in incoming.shipments {
                guard let record = incoming.records.first(where: { $0.shipmentID == shipment.id }) else {
                    throw PickupStorageError.invalidData("运单关联记录缺失")
                }
                if let collision = current.records.first(where: { $0.id == record.id }),
                   collision.shipmentID != matches[shipment.id] {
                    throw PickupStorageError.invalidData("取码记录 ID 与其他记录冲突，无法安全合并")
                }
            }
            merge(&current.groups, incoming.groups)
            // Absence in an old backup never clears newly introduced train data.
            if let incomingTickets = incoming.trainTickets {
                var tickets = current.trainTickets ?? []
                merge(&tickets, incomingTickets)
                current.trainTickets = tickets
            }
            if let incomingBindings = incoming.trainWidgetBindings {
                var bindings = current.trainWidgetBindings ?? []
                for binding in incomingBindings {
                    if let index = bindings.firstIndex(where: { $0.slot == binding.slot }) {
                        if policy == .replaceExisting { bindings[index] = binding }
                    } else { bindings.append(binding) }
                }
                current.trainWidgetBindings = bindings
            }
            // Merge never changes an existing default; fill an unset default from the backup.
            if current.expressGroupID == nil { current.expressGroupID = incoming.expressGroupID }
            for shipment in incoming.shipments {
                guard let record = incoming.records.first(where: { $0.shipmentID == shipment.id }) else {
                    throw PickupStorageError.invalidData("运单关联记录缺失")
                }
                let oldID = matches[shipment.id]
                let oldRecord = oldID.flatMap { id in current.records.first { $0.shipmentID == id } }
                // An incoming record ID belonging to a different entity cannot be reassigned safely.
                if let collision = current.records.first(where: { $0.id == record.id }), collision.id != oldRecord?.id {
                    throw PickupStorageError.invalidData("取码记录 ID 与其他记录冲突，无法安全合并")
                }
                if let oldID = oldID {
                    if policy == .replaceExisting {
                        current.shipments.removeAll { $0.id == oldID }
                        current.records.removeAll { $0.shipmentID == oldID }
                        current.shipments.append(shipment)
                        current.records.append(record)
                    }
                } else {
                    current.shipments.append(shipment)
                    current.records.append(record)
                }
            }
            for record in incoming.records where record.shipmentID == nil {
                if let index = current.records.firstIndex(where: { $0.id == record.id }) {
                    guard current.records[index].shipmentID == nil else { throw PickupStorageError.invalidData("记录 ID 关联不同运单，无法安全合并") }
                    if policy == .replaceExisting { current.records[index] = record }
                } else { current.records.append(record) }
            }
            // Never rewrite an existing record implicitly. Reject coupled conflicts instead.
            try validate(current)
            return current
        }
    }
}
