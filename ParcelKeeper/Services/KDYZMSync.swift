import Foundation
import WidgetKit

enum KDYZMTime {
    static func date(_ milliseconds: Double) throws -> Date? {
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds.rounded() == milliseconds,
              milliseconds <= 253_402_300_799_000 else { throw KDYZMError.invalid }
        return milliseconds == 0 ? nil : Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
struct KDYZMOrder: Decodable {
    var id: String
    var accountId: String
    var platform: String
    var platformOrderId: String
    var familyId: String? = nil
    var title: String? = nil
}
struct KDYZMRemoteShipment: Decodable {
    var id: String
    var orderId: String
    var accountId: String
    var familyId: String? = nil
    var waybillNo: String
    var carrier: String
    var status: String
    var pickupCode: String? = nil
    var station: String? = nil
    var arrivalAt: Double? = nil
    var updatedAt: Double? = nil
    var picked: Bool? = nil
    var hidden: Bool? = nil
    var deleted: Bool? = nil
    var logisticsEvents: [KDYZMLogisticsEvent]? = nil
    var logisticsState: String? = nil
    var logisticsCheckedAt: Double? = nil
    var logisticsUpdatedAt: Double? = nil
    var logisticsTruncated: Bool? = nil
}
struct KDYZMSnapshot: Decodable {
    var schemaVersion: Int
    var serverRevision: Int
    var accounts: [KDYZMAccount]
    var orders: [KDYZMOrder]
    var shipments: [KDYZMRemoteShipment]
    var hiddenIds: [String]
    var deletedIds: [String]
    var familyIds: [String]?
    var legacyAccountIds: [String]?
    var families: [KDYZMFamily]?

    func validated() throws -> Self {
        func unique(_ ids: [String]) throws {
            guard Set(ids).count == ids.count else { throw KDYZMError.invalid }
            for id in ids { _ = try KDYZMClient.segment(id) }
        }
        guard schemaVersion == 1, serverRevision >= 0 else { throw KDYZMError.invalid }
        try unique(accounts.map(\.id)); try unique(orders.map(\.id)); try unique(shipments.map(\.id))
        try unique(hiddenIds); try unique(deletedIds); try unique(familyIds ?? []); try unique(legacyAccountIds ?? [])
        try unique((families ?? []).map(\.id))
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let orderMap = Dictionary(uniqueKeysWithValues: orders.map { ($0.id, $0) })
        func authorized(account: String, family: String?) -> Bool {
            if let familyIds {
                // Presence, even [], switches off accounts-as-scope compatibility.
                return familyIds.contains(family ?? "") || (legacyAccountIds ?? []).contains(account)
            }
            return accountMap[account] != nil
        }
        for account in accounts {
            guard authorized(account: account.id, family: account.familyId) else { throw KDYZMError.forbidden }
        }
        for order in orders {
            _ = try KDYZMClient.segment(order.accountId)
            guard !order.platform.isEmpty,
                  !order.platform.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw KDYZMError.invalid }
            guard authorized(account: order.accountId, family: order.familyId),
                  accountMap[order.accountId].map({ $0.platform == order.platform }) ?? true else { throw KDYZMError.forbidden }
        }
        var identities = Set<String>()
        for shipment in shipments {
            guard let order = orderMap[shipment.orderId], order.accountId == shipment.accountId,
                  (order.familyId ?? "") == (shipment.familyId ?? ""),
                  authorized(account: shipment.accountId, family: shipment.familyId),
                  ["transit", "arrived", "signed", "unknown"].contains(shipment.status),
                  shipment.logisticsState.map({ ["", "ok", "empty", "error", "unavailable"].contains($0) }) ?? true else { throw KDYZMError.invalid }
            guard (shipment.pickupCode ?? "").count <= 80, (shipment.station ?? "").count <= 200,
                  (order.title ?? "").count <= 500, shipment.carrier.count <= 120,
                  [shipment.pickupCode ?? "", shipment.station ?? "", order.title ?? ""].allSatisfy({ text in
                      !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
                  }) else { throw KDYZMError.invalid }
            let number = CarrierDetector.sanitize(shipment.waybillNo)
            // Backend order identity permits combined shipping to reuse a waybill.
            let key = shipment.accountId + ":" + shipment.orderId + ":" + carrierKey(shipment.carrier) + ":" + number
            if !number.isEmpty { guard identities.insert(key).inserted else { throw KDYZMError.invalid } }
            for time in [shipment.arrivalAt, shipment.updatedAt, shipment.logisticsCheckedAt, shipment.logisticsUpdatedAt].compactMap({ $0 }) { _ = try KDYZMTime.date(time) }
            let events = shipment.logisticsEvents ?? []
            guard events.count <= 100, Set(events).count == events.count else { throw KDYZMError.invalid }
            for event in events {
                _ = try KDYZMTime.date(event.time)
                guard !event.description.isEmpty, event.description.count <= 600, event.location.count <= 120,
                      event.timeText.count <= 100 else { throw KDYZMError.invalid }
            }
        }
        return self
    }
    private func carrierKey(_ raw: String) -> String { KDYZMMerger.carrierKey(raw) }
}

struct KDYZMSyncReport {
    var imported = 0
    var updated = 0
    var unchanged = 0
    var skipped = 0
    var noWaybill = 0
    var message: String {
        "新增 \(imported) 票，更新 \(updated) 票，未变化 \(unchanged) 票，跳过 \(skipped) 票；\(noWaybill) 个订单尚无运单。同步只读取后台快照，不代表后台已完成平台采集；零订单也不保证购物账号没有订单。"
    }
}
/// Flat ordered union of history lines. Merge content, not nested snapshots: this
/// preserves intermediate paid/platform histories through repeated source switches
/// without recursively embedding the previous aggregate or duplicating nodes.
enum TrackingQueryHistory {
    static func merged(_ histories: String?...) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for history in histories.compactMap({ $0 }) {
            for line in history.components(separatedBy: "\n") {
                if line == "【原有历史】" { continue } // flatten legacy aggregate marker
                if seen.insert(line).inserted { lines.append(line) }
            }
        }
        return lines.joined(separator: "\n")
    }
}

enum KDYZMMerger {
    static func carrierKey(_ raw: String) -> String {
        if let c = CarrierDetector.carrierMentioned(in: raw) { return c.code }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if CarrierDetector.allCarriers.contains(where: { $0.code == key }) { return key }
        return key
    }
    // Missing remote metadata is acceptable only after an exact backend binding match.
    static func acceptsCarrier(_ raw: String, local: Shipment, exactBinding: Bool) -> Bool {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return exactBinding }
        return carrierKey(local.carrierName) == carrierKey(raw) || local.carrierCode == carrierKey(raw)
    }
    // A combined parcel may have multiple order bindings, but never crosses accounts/platforms.
    static func sameParcel(_ lhs: Shipment, _ rhs: Shipment) -> Bool {
        guard let a = lhs.backendBinding, let b = rhs.backendBinding,
              a.origin == b.origin, a.accountID == b.accountID,
              let platform = lhs.originPlatform, platform == rhs.originPlatform,
              !CarrierDetector.sanitize(lhs.trackingNumber).isEmpty,
              CarrierDetector.sanitize(lhs.trackingNumber) == CarrierDetector.sanitize(rhs.trackingNumber) else { return false }
        let left = carrierKey(lhs.carrierName), right = carrierKey(rhs.carrierName)
        return !left.isEmpty && left != CarrierDetector.unknown.name && left == right
    }
    private static func conflictingPickup(code: String, groupID: UUID, shipment: Shipment, in data: PickupDataset) -> Bool {
        data.records.contains { record in
            guard record.shipmentID != shipment.id, !record.isCompleted, record.groupID == groupID,
                  record.code.trimmingCharacters(in: .whitespacesAndNewlines) == code.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            guard let id = record.shipmentID, let other = data.shipments.first(where: { $0.id == id }) else { return true }
            return !sameParcel(shipment, other)
        }
    }
    static func sameIdentity(_ current: Shipment, _ before: Shipment) -> Bool {
        current.id == before.id && current.backendBinding == before.backendBinding &&
        current.trackingNumber == before.trackingNumber && current.carrierCode == before.carrierCode &&
        current.carrierName == before.carrierName && current.originPlatform == before.originPlatform &&
        current.refreshChannel == before.refreshChannel && current.platformOrderID == before.platformOrderID &&
        current.taobaoOrderID == before.taobaoOrderID && current.uapiCarrierCode == before.uapiCarrierCode
    }
    static func update(_ remote: KDYZMRemoteShipment, local: inout Shipment, refresh: Bool = false, operation: UUID? = nil) throws -> Bool {
        guard local.status != .archived else { return false }
        let original = local
        // Failed/empty cache responses never clear history, and never count as a successful refresh.
        guard remote.logisticsState == "ok", let incoming = remote.logisticsEvents, !incoming.isEmpty,
              let successTime = try KDYZMTime.date(remote.logisticsUpdatedAt ?? 0) else { return false }
        let latest = incoming.compactMap { try? KDYZMTime.date($0.time) }.max()
        let latestDescriptions = incoming.filter { (try? KDYZMTime.date($0.time)) == latest }.map(\.description)
        let recipientCollected = latest != nil && MallDeliveryState.recipientCollected(events: latestDescriptions)
        // Event ordering selects the main node within this response only.
        // Older/equal remote times never block it from replacing the saved main node.
        let combined = Array(Set((local.backendEvents ?? []) + incoming)).sorted {
            $0.time == $1.time ? $0.description < $1.description : $0.time > $1.time
        }
        let priorHistory = local.logisticsSource != "kdyzm" || local.backendEvents == nil
            ? TrackingQueryHistory.merged(local.queryInfo, local.backendPreviousHistory)
            : TrackingQueryHistory.merged(local.backendPreviousHistory)
        local.backendPreviousHistory = priorHistory.isEmpty ? nil : priorHistory
        local.backendEvents = combined
        local.backendLogisticsUpdatedAt = successTime
        local.logisticsInfo = incoming.sorted {
            $0.time == $1.time ? $0.description < $1.description : $0.time > $1.time
        }.first?.description
        local.logisticsTime = latest

        local.queryInfo = combined.map {
            let time = (try? KDYZMTime.date($0.time)).map { ShipmentDateDisplay.string($0) } ?? $0.timeText
            return [time, $0.description, $0.location].filter { !$0.isEmpty }.joined(separator: " · ")
        }.joined(separator: "\n") + (remote.logisticsTruncated == true ? "\n【后台轨迹已截断，非完整历史；本地已有节点保留】" : "")
        local.queryInfo = TrackingQueryHistory.merged(local.queryInfo, priorHistory)
        // signed is a logistics fact, not proof the user collected the parcel.
        // Never mutate PickupRecord.isCompleted from remote signed/picked.
        if recipientCollected { local.status = .delivered }
        if local.status != .archived && local.status != .delivered {
            switch remote.status {
            case "signed": local.status = .delivered
            case "arrived": local.status = .readyForPickup
            case "transit": local.status = .inTransit
            default: break
            }
        }
        local.logisticsSource = "kdyzm"; local.lastRefreshError = nil
        if refresh { local.lastQueriedAt = Date() }
        if local != original { local.updatedAt = Date() }
        return true
    }
    @discardableResult
    static func apply(_ snapshot: KDYZMSnapshot, origin: String, to data: inout PickupDataset, operation: UUID? = nil) throws -> KDYZMSyncReport {
        _ = try snapshot.validated()
        _ = try KDYZMOrigin(origin)
        var result = KDYZMSyncReport()
        let orders = Dictionary(uniqueKeysWithValues: snapshot.orders.map { ($0.id, $0) })
        let remoteNumbers = Dictionary(grouping: snapshot.shipments.filter { !CarrierDetector.sanitize($0.waybillNo).isEmpty }, by: { CarrierDetector.sanitize($0.waybillNo) })
        let existingBindings = data.shipments.compactMap(\.backendBinding)
        guard Set(existingBindings).count == existingBindings.count else { throw KDYZMError.invalid }
        result.noWaybill = snapshot.orders.filter { order in
            !snapshot.shipments.contains { $0.orderId == order.id && !CarrierDetector.sanitize($0.waybillNo).isEmpty }
        }.count
        for remote in snapshot.shipments {
            guard let order = orders[remote.orderId],
                  !snapshot.hiddenIds.contains(remote.id), !snapshot.deletedIds.contains(remote.id),
                  remote.hidden != true, remote.deleted != true,
                  !CarrierDetector.sanitize(remote.waybillNo).isEmpty else { result.skipped += 1; continue }
            let number = try ShipmentShortcutParser.number(CarrierDetector.sanitize(remote.waybillNo))
            let binding = KDYZMBinding(origin: origin, accountID: remote.accountId, orderID: remote.orderId, shipmentID: remote.id)
            let exact = data.shipments.indices.filter { data.shipments[$0].backendBinding == binding }
            guard exact.count <= 1 else { throw KDYZMError.invalid }
            var index = exact.first
            if index == nil {
                let candidates = data.shipments.indices.filter { CarrierDetector.sanitize(data.shipments[$0].trackingNumber) == number && data.shipments[$0].backendBinding == nil }
                // Never attach an unbound ticket if two authorized accounts share the number.
                guard candidates.count <= 1, candidates.isEmpty || remoteNumbers[number]?.count == 1 else { throw KDYZMError.invalid }
                if let candidate = candidates.first {
                    let local = data.shipments[candidate]
                    guard !remote.carrier.isEmpty, carrierKey(local.carrierName) == carrierKey(remote.carrier) || local.carrierCode == carrierKey(remote.carrier),
                          local.taobaoOrderID == nil,
                          local.originPlatform == nil || local.originPlatform == "manual" ||
                            (local.originPlatform == order.platform && local.platformOrderID == order.platformOrderId),
                          local.platformOrderID == nil || local.platformOrderID == order.platformOrderId else { throw KDYZMError.invalid }
                    index = candidate
                }
            }
            if let index {
                var local = data.shipments[index]
                let original = local
                guard local.status != .archived else { result.skipped += 1; continue }
                if local.backendBinding != nil {
                    guard local.originPlatform == order.platform, local.platformOrderID == order.platformOrderId else { throw KDYZMError.stale }
                }
                guard CarrierDetector.sanitize(local.trackingNumber) == number,
                      acceptsCarrier(remote.carrier, local: local, exactBinding: local.backendBinding == binding) else { throw KDYZMError.stale }
                local.backendBinding = binding; local.originPlatform = order.platform
                local.platformOrderID = order.platformOrderId
                // Only explicit overrides opt out; historical source is not routing.
                if local.refreshChannel == nil {
                    _ = try update(remote, local: &local, operation: operation)
                }
                let code = remote.pickupCode ?? ""
                if local.pickupCode.isEmpty, !code.isEmpty {
                    let linked = data.records.indices.filter { data.records[$0].shipmentID == local.id }
                    guard linked.count == 1, let record = linked.first, data.records[record].code.isEmpty else { throw KDYZMError.invalid }
                    let target = data.records[record]
                    guard target.isCompleted || !conflictingPickup(code: code, groupID: target.groupID, shipment: local, in: data) else { throw KDYZMError.invalid }
                    local.pickupCode = code
                    data.records[record].code = code
                }
                data.shipments[index] = local
                if local != original { result.updated += 1 }
                else { result.unchanged += 1 }
            } else {
                guard let group = data.expressGroupID, data.groups.contains(where: { $0.id == group }) else { throw KDYZMError.invalid }
                let detection = CarrierDetector.detect(number, context: remote.carrier)
                // Remote metadata seeds new tickets, never implies manual collection.
                let pickupCode = remote.pickupCode ?? ""
                var local = Shipment(trackingNumber: number, carrierName: remote.carrier.isEmpty ? detection.carrier.name : remote.carrier,
                                     carrierCode: detection.carrier.code, note: order.title ?? "", pickupCode: pickupCode,
                                     originPlatform: order.platform, platformOrderID: order.platformOrderId)
                local.backendBinding = binding
                guard pickupCode.isEmpty || !conflictingPickup(code: pickupCode, groupID: group, shipment: local, in: data) else { throw KDYZMError.invalid }
                switch remote.status {
                case "signed": local.status = .delivered
                case "arrived": local.status = .readyForPickup
                default: break
                }
                _ = try update(remote, local: &local, operation: operation)
                data.shipments.append(local)
                data.records.append(PickupRecord(groupID: group, code: local.pickupCode, location: remote.station ?? "", source: local.note, isCompleted: false, shipmentID: local.id))
                result.imported += 1
            }
        }
        return result
    }
}

struct KDYZMJob: Decodable {
    var id: String
    var accountId: String
    var orderId: String
    var state: String
    var retryAt: Double? = nil
    var logisticsState: String? = nil
    var createdAt: Double? = nil
    func success(for binding: KDYZMBinding, expectedID: String? = nil) throws -> Bool {
        _ = try KDYZMClient.segment(id)
        guard expectedID.map({ id == $0 }) ?? true, accountId == binding.accountID, orderId == binding.orderID,
              ["queued", "running", "cooldown", "disabled", "completed", "expired", "error"].contains(state) else { throw KDYZMError.invalid }
        _ = try KDYZMTime.date(retryAt ?? 0)
        _ = try KDYZMTime.date(createdAt ?? 0)
        return state == "completed" && logisticsState == "ok"
    }
}

/// Fixed user-facing diagnostic, never contains server content or credentials.
struct KDYZMTerminalResultError: LocalizedError {
    var originalReason: DiagnosticReason = .terminalResult
    var originalStage: DiagnosticStage = .merge
    var cleanupReason: DiagnosticReason? = nil
    var errorDescription: String? {
        if cleanupReason != nil { return "后台终态结果不可用，任务清理未完成；未覆盖本地轨迹，本次未重复提交，请检查后重试。" }
        return "后台终态任务已清除，但结果身份冲突或不可用，未覆盖本地轨迹；本次未重复提交，可检查后再次手动刷新。"
    }
}

struct KDYZMRefreshService {
    let store: SharedPickupStore
    var connection: KDYZMConnection = .shared
    var client = KDYZMClient()
    var budget: TimeInterval = 12
    var reloadWidgets: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    var diagnosticLog: DiagnosticLog = .shared
    func refresh(before: Shipment, operation: UUID = UUID(), trace suppliedTrace: DiagnosticTrace? = nil) async throws -> Bool {
        let trace = suppliedTrace ?? DiagnosticTrace(operation: operation, log: diagnosticLog)
        trace.begin(.lease)
        do { try await connection.beginRefresh(before.id) }
        catch { trace.fail(error); throw error }
        do {
            let result = try await perform(before: before, trace: trace)
            trace.finish()
            await connection.endRefresh(before.id)
            return result
        } catch {
            trace.fail(error)
            await connection.endRefresh(before.id)
            throw error
        }
    }
    private func perform(before: Shipment, trace: DiagnosticTrace) async throws -> Bool {
        guard !store.isReadOnly, let binding = before.backendBinding else { throw KDYZMError.invalid }
        trace.begin(.credential)
        let credential = try await connection.credential()
        guard credential.baseURL == binding.origin else { throw KDYZMError.stale }
        let start = ProcessInfo.processInfo.systemUptime
        func remainingTimeout() throws -> TimeInterval {
            let remaining = budget - (ProcessInfo.processInfo.systemUptime - start)
            guard remaining > 0 else { throw KDYZMError.queued }
            return min(12, remaining)
        }
        // Network never holds a tracking lease or dataset transaction. All commits
        // validate the credential generation inside KDYZMConnection.commit.
        struct Accepted: Decodable { var accepted: Bool; var jobs: [KDYZMJob] }
        struct ReadJob: Decodable { var job: KDYZMJob }
        var job: KDYZMJob
        if let pending = before.backendRefreshJobID {
            trace.begin(.jobResume)
            guard before.backendRefreshGeneration == credential.generation else {
                throw await cleanupFailure(KDYZMError.stale, id: pending, before: before, credential: credential, trace: trace)
            }
            do {
                job = try await client.request(ReadJob.self, origin: binding.origin, path: "/v1/sync-jobs/" + KDYZMClient.segment(pending), credential: credential, timeout: remainingTimeout()).job
            } catch KDYZMError.jobGone {
                throw await cleanupFailure(KDYZMError.jobGone, id: pending, before: before, credential: credential, trace: trace)
            }
            _ = try job.success(for: binding, expectedID: pending)
        } else {
            trace.begin(.jobCreate)
            let response = try await client.request(Accepted.self, origin: binding.origin,
                path: "/v1/orders/" + KDYZMClient.segment(binding.orderID) + "/refresh", method: "POST", body: [:], credential: credential, status: 202, timeout: remainingTimeout())
            guard response.accepted, response.jobs.count == 1, let first = response.jobs.first else { throw KDYZMError.invalid }
            job = first
            _ = try job.success(for: binding)
            trace.begin(.save)
            try await connection.commit(credential) {
                let lease = try store.acquireTrackingQuery(id: before.id); defer { lease.release() }
                try store.transaction { data in
                    guard let index = data.shipments.firstIndex(where: { $0.id == before.id }),
                          KDYZMMerger.sameIdentity(data.shipments[index], before),
                          data.shipments[index].backendRefreshJobID == nil else { throw KDYZMError.stale }
                    data.shipments[index].backendRefreshJobID = first.id
                    data.shipments[index].backendRefreshGeneration = credential.generation
                }
            }
        }
        trace.begin(.jobWait) // Saving the accepted ID succeeded; waiting is not a write.
        let expectedID = job.id
        while true {
            try Task.checkCancellation()
            try await connection.verify(credential)
            if try job.success(for: binding, expectedID: expectedID) { break }
            if ["disabled", "completed", "expired", "error", "cooldown"].contains(job.state) {
                // Cooldown means queue full in the pinned server, not an accepted queued job.
                let original = job.state == "cooldown" ? KDYZMError.queued : KDYZMError.failed
                throw await cleanupFailure(original, id: expectedID, before: before, credential: credential, trace: trace)
            }
            let remaining = budget - (ProcessInfo.processInfo.systemUptime - start)
            let delay = max(0.5, (job.retryAt ?? 0) / 1000 - Date().timeIntervalSince1970)
            guard remaining > delay + 1 else { throw KDYZMError.queued }
            try await Task.sleep(nanoseconds: UInt64(min(delay, 10) * 1_000_000_000))
            trace.begin(.jobPoll)
            do {
                job = try await client.request(ReadJob.self, origin: binding.origin,
                    path: "/v1/sync-jobs/" + KDYZMClient.segment(expectedID), credential: credential, timeout: remainingTimeout()).job
            } catch KDYZMError.jobGone {
                throw await cleanupFailure(KDYZMError.jobGone, id: expectedID, before: before, credential: credential, trace: trace)
            }
        }
        // Completion is terminal even when its snapshot is rejected. Cleanup must
        // be a separate transaction: a throw inside the merge rolls its writes back.
        var newlyDelivered = false
        do {
        trace.begin(.snapshot)
        let snapshot = try await client.snapshot(credential, timeout: remainingTimeout())
        trace.begin(.merge)
        _ = try remainingTimeout()
        try Task.checkCancellation()
        guard let remote = snapshot.shipments.first(where: { $0.id == binding.shipmentID && $0.accountId == binding.accountID && $0.orderId == binding.orderID }),
              snapshot.orders.contains(where: { $0.id == binding.orderID && $0.accountId == binding.accountID && $0.platform == before.originPlatform && $0.platformOrderId == before.platformOrderID }),
              !snapshot.hiddenIds.contains(remote.id), !snapshot.deletedIds.contains(remote.id), remote.hidden != true, remote.deleted != true,
              CarrierDetector.sanitize(remote.waybillNo) == CarrierDetector.sanitize(before.trackingNumber),
              KDYZMMerger.acceptsCarrier(remote.carrier, local: before, exactBinding: true) else { throw KDYZMError.stale }
        guard remote.logisticsState == "ok", !(remote.logisticsEvents ?? []).isEmpty else {
            throw KDYZMError.empty
        }
        trace.begin(.save)
        try await connection.commit(credential) {
            let lease = try store.acquireTrackingQuery(id: before.id); defer { lease.release() }
            try store.transaction { data in
                guard let index = data.shipments.firstIndex(where: { $0.id == before.id }),
                      KDYZMMerger.sameIdentity(data.shipments[index], before),
                      data.shipments[index].backendRefreshJobID == expectedID,
                      data.shipments[index].backendRefreshGeneration == credential.generation,
                      data.records.contains(where: { $0.shipmentID == before.id }),
                      data.shipments[index].status != .archived else { throw KDYZMError.stale }
                let wasDelivered = data.shipments[index].status == .delivered
                trace.begin(.merge)
                guard try KDYZMMerger.update(remote, local: &data.shipments[index], refresh: true, operation: trace.operation) else { throw KDYZMError.empty }
                newlyDelivered = !wasDelivered && data.shipments[index].status == .delivered
                data.shipments[index].backendRefreshJobID = nil
                data.shipments[index].backendRefreshGeneration = nil
                trace.begin(.save)
                // Record completion, code, group, location, source and reminder remain local.
            }
        }
        } catch {
            // Matching ID + identity + generation protects a newly accepted job.
            // A cleanup/authorization/lease failure remains an explicit error.
            throw await cleanupFailure(error, id: expectedID, before: before, credential: credential, trace: trace, terminalResult: true)
        }
        reloadWidgets()
        return newlyDelivered // Shipment transition only; manual pickup remains local.
    }
    /// Cleanup records its own failure, never replaces the triggering reason/stage,
    /// and never submits another POST. Successful cooldown cleanup preserves .queued.
    private func cleanupFailure(_ original: Error, id expectedID: String, before: Shipment, credential: KDYZMCredential, trace: DiagnosticTrace, terminalResult: Bool = false) async -> Error {
        let originalReason = TrackingRefreshService.diagnosticReason(original)
        let originalStage = trace.stage ?? trace.failureStage ?? .merge
        trace.fail(original)
        trace.begin(.cleanup)
        var cleanupReason: DiagnosticReason?
        do { try await clearJob(expectedID, before: before, credential: credential); trace.finish() }
        catch { cleanupReason = TrackingRefreshService.diagnosticReason(error); trace.fail(error) }
        reloadWidgets()
        if original is CancellationError { return original }
        if cleanupReason == nil, !terminalResult { return original }
        return KDYZMTerminalResultError(originalReason: originalReason, originalStage: originalStage, cleanupReason: cleanupReason)
    }
    private func clearJob(_ id: String, before: Shipment, credential: KDYZMCredential) async throws {
        try await connection.commit(credential) {
            let lease = try store.acquireTrackingQuery(id: before.id); defer { lease.release() }
            try store.transaction { data in
                guard let i = data.shipments.firstIndex(where: { $0.id == before.id }),
                      KDYZMMerger.sameIdentity(data.shipments[i], before), data.shipments[i].backendRefreshJobID == id,
                      data.shipments[i].backendRefreshGeneration == (before.backendRefreshJobID == id ? before.backendRefreshGeneration : credential.generation) else { throw KDYZMError.stale }
                data.shipments[i].backendRefreshJobID = nil
                data.shipments[i].backendRefreshGeneration = nil
            }
        }
    }
}

