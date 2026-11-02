import Foundation
import WidgetKit

enum TrackingRefreshMode: String, Codable, CaseIterable {
    case automatic, platformOnly, uapi
}

struct TrackingRefreshReport {
    var succeeded = 0
    var skipped = 0
    /// Number of tickets dispatched to each source (successes and failures).
    var taobaoCount = 0
    var uapiCount = 0
    struct Failure {
        let trackingNumber: String
        let reason: String
    }
    var failures: [Failure] = []
    var failed: Int { failures.count }
    var newlyDelivered = 0
    var remaining = 0
    var stoppedReason: String?
    var message: String {
        var value = "更新成功 \(succeeded) 票，失败 \(failed) 票，新增签收 \(newlyDelivered) 票，未处理 \(remaining) 票。"
        value += " 淘宝派发\(taobaoCount)票，UAPI派发\(uapiCount)票（实际收费以接口为准）。"
        if skipped > 0 { value += " 跳过 \(skipped) 票。" }
        if let stoppedReason { value += " \(stoppedReason)" }
        for failure in failures { value += "\n\(failure.trackingNumber)：\(failure.reason)" }
        return value
    }
}

/// App buttons and AppIntents share this service. Network awaits never hold flock.
struct TrackingRefreshService {
    let store: SharedPickupStore
    let client: any UAPITrackingQuerying
    var reloadWidgets: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var phones = ShipmentPhoneStore()
    var taobaoClient: any TaobaoTrackingQuerying = TaobaoTrackingClient()

    private enum Route: Equatable { case taobao, uapi }
    private static func isTaobao(_ shipment: Shipment) -> Bool {
        shipment.originPlatform == "taobao" || shipment.taobaoOrderID != nil
    }
    private static func route(_ shipment: Shipment, mode: TrackingRefreshMode) throws -> Route {
        if mode == .uapi { return .uapi }
        if mode == .platformOnly {
            guard isTaobao(shipment) else { throw TaobaoTrackingError.unsupported }
            return .taobao
        }
        if shipment.refreshChannel == "uapi" { return .uapi }
        guard shipment.refreshChannel == nil else { throw TaobaoTrackingError.unsupported }
        if isTaobao(shipment) { return .taobao }
        // Missing origin is the legacy/manual UAPI path, not a platform fallback.
        guard shipment.originPlatform == nil || shipment.originPlatform == "manual" || shipment.originPlatform == "uapi" else {
            throw TaobaoTrackingError.unsupported
        }
        return .uapi
    }
    func setRefreshChannel(id: UUID, channel: String?) throws {
        guard channel == nil || channel == "uapi" else { throw TaobaoTrackingError.unsupported }
        let lease = try store.acquireTrackingQuery(id: id)
        defer { lease.release() }
        try store.transaction { data in
            guard let index = data.shipments.firstIndex(where: { $0.id == id }) else { throw PickupStorageError.notFound }
            data.shipments[index].refreshChannel = channel
        }
        reloadWidgets()
    }

    private static func safeReason(_ error: Error) -> String {
        if let failure = error as? TaobaoTrackingError {
            switch failure {
            case .missingBinding: return "淘宝订单关联缺失，请重新绑定后刷新。"
            case .unsupported: return "此记录不支持所选平台刷新，未切换查询渠道。"
            case .identityMismatch: return "淘宝运单身份不匹配，未更新。"
            case .noTrace: return "淘宝暂无可用物流轨迹，保留上次结果。"
            case .authentication: return "淘宝登录已失效，请在 App 重新登录。"
            case .verification: return "淘宝需要验证，请在 App 完成验证。"
            }
        }
        if let failure = error as? UAPIError { return failure.localizedDescription }
        if let failure = error as? ShipmentShortcutError { return failure.localizedDescription }
        if let failure = error as? PickupStorageError {
            switch failure {
            case .queryInProgress: return failure.localizedDescription
            case .stalePreview: return "查询期间快递信息已更改，未覆盖；请重新查询。"
            case .notFound: return "快递记录已删除或关联记录缺失，未更新。"
            default: return "快递存储或共享访问失败，未更新；请在 App 检查。"
            }
        }
        return "查询或保存失败，未更新；请在 App 检查。"
    }
    private static func sameIdentity(_ current: Shipment, _ before: Shipment) -> Bool {
        current.id == before.id &&
        CarrierDetector.sanitize(current.trackingNumber) == CarrierDetector.sanitize(before.trackingNumber) &&
        current.originPlatform == before.originPlatform && current.taobaoOrderID == before.taobaoOrderID &&
        current.refreshChannel == before.refreshChannel && current.carrierCode == before.carrierCode &&
        current.uapiCarrierCode == before.uapiCarrierCode &&
        (current.carrierCode != CarrierDetector.unknown.code ||
         current.carrierName.trimmingCharacters(in: .whitespacesAndNewlines) == before.carrierName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func savedPhone(id: UUID) throws -> String? {
        guard let shipment = try store.snapshot().shipments.first(where: { $0.id == id }) else { throw PickupStorageError.notFound }
        return try phones.read(for: shipment)
    }
    /// Nil clears this ticket; refresh(nil) instead reuses its saved value.
    func setPhone(id: UUID, phone: String?) throws {
        let lease = try store.acquireTrackingQuery(id: id)
        defer { lease.release() }
        guard let shipment = try store.snapshot().shipments.first(where: { $0.id == id }) else { throw PickupStorageError.notFound }
        if let phone { try phones.save(phone, for: shipment) }
        else { try phones.clear(for: shipment) }
    }
    static func live() throws -> TrackingRefreshService {
        TrackingRefreshService(store: try SharedPickupStore(appGroupID: nil, accessMode: .existingSharedData), client: UAPITrackingClient())
    }
    static func isPending(_ shipment: Shipment) -> Bool {
        shipment.status != .delivered && shipment.status != .archived
    }
    func refresh(trackingNumber: String, phone: String? = nil, mode: TrackingRefreshMode = .automatic) async throws -> Bool {
        let number = try ShipmentShortcutParser.number(trackingNumber)
        let matches = try store.snapshot().shipments.filter { CarrierDetector.sanitize($0.trackingNumber) == number }
        guard matches.count == 1, let shipment = matches.first else {
            if matches.isEmpty { throw PickupStorageError.notFound }
            throw ShipmentShortcutError.ambiguous
        }
        return try await refresh(id: shipment.id, phone: phone, mode: mode)
    }
    /// Returns whether this update newly completed a shipment.
    func refresh(id: UUID, phone: String? = nil, expectedTrackingNumber: String? = nil, pendingOnly: Bool = false, mode: TrackingRefreshMode = .automatic) async throws -> Bool {
        try Task.checkCancellation()
        let lease = try store.acquireTrackingQuery(id: id)
        defer { lease.release() }
        let snapshot = try store.snapshot()
        guard let before = snapshot.shipments.first(where: { $0.id == id }) else { throw PickupStorageError.notFound }
        guard before.status != .archived else { throw ShipmentShortcutError.statusConflict }
        guard !pendingOnly || Self.isPending(before) else { throw ShipmentShortcutError.statusConflict }
        let number = try ShipmentShortcutParser.number(before.trackingNumber)
        if let expectedTrackingNumber, number != expectedTrackingNumber { throw PickupStorageError.stalePreview }
        let linkedID = snapshot.records.first(where: { $0.shipmentID == id })?.id
        do {
        let route = try Self.route(before, mode: mode)
        let result: UAPITrackingResult
        switch route {
        case .taobao:
            guard let orderID = before.taobaoOrderID, !orderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TaobaoTrackingError.missingBinding
            }
            result = try await taobaoClient.query(orderID: orderID, trackingNumber: number)
        case .uapi:
        // Shortcut optional text can arrive as "" instead of nil. Only an
        // entirely blank input means omitted; never repair nonblank credentials.
        let suppliedPhone: String?
        if let phone, !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            suppliedPhone = phone
        } else {
            suppliedPhone = nil
        }
        // Save before the charged request. Blank input reuses, never clears.
        if let suppliedPhone { try phones.save(suppliedPhone, for: before) }
        let queryPhone: String?
        if let suppliedPhone { queryPhone = suppliedPhone } else { queryPhone = try phones.read(for: before) }
        result = try await client.query(trackingNumber: number, carrierCode: before.uapiCarrierCode, phone: queryPhone, refresh: true)
        }
        try Task.checkCancellation()
        guard result.trackingNumber == number else {
            if route == .taobao { throw TaobaoTrackingError.identityMismatch }
            throw UAPIError.invalidResponse
        }
        let delivered = try store.transaction { data -> Bool in
            guard let index = data.shipments.firstIndex(where: { $0.id == id }),
                  CarrierDetector.sanitize(data.shipments[index].trackingNumber) == number else { throw PickupStorageError.notFound }
            var current = data.shipments[index]
            guard Self.sameIdentity(current, before) else { throw PickupStorageError.stalePreview }
            guard current.status != .archived else { throw ShipmentShortcutError.statusConflict }
            if let old = current.logisticsTime {
                guard let incoming = result.logisticsTime, incoming >= old else { throw ShipmentShortcutError.olderUpdate }
            }
            if let queried = current.lastQueriedAt, result.queriedAt < queried { throw ShipmentShortcutError.olderUpdate }
            if current.status == .delivered, let state = result.status, state != .delivered { throw ShipmentShortcutError.statusConflict }
            guard let linked = data.records.firstIndex(where: { $0.shipmentID == id }),
                  data.records[linked].id == linkedID else { throw PickupStorageError.invalidData("运单关联记录缺失或已改变") }
            let oldStatus = current.status
            current.logisticsInfo = result.logisticsInfo
            current.logisticsTime = result.logisticsTime
            current.queryInfo = result.queryInfo
            current.lastQueriedAt = result.queriedAt
            if !result.carrierName.isEmpty { current.carrierName = result.carrierName }
            if route == .uapi, !result.carrierCode.isEmpty { current.uapiCarrierCode = result.carrierCode }
            current.logisticsSource = route == .taobao ? "taobao" : "uapi"
            current.lastRefreshError = nil
            if let state = result.status { current.status = state }
            current.updatedAt = Date()
            if current.status != oldStatus {
                let completed = current.status == .delivered
                let previous = data.records[linked]
                let code = previous.code.trimmingCharacters(in: .whitespacesAndNewlines)
                if previous.isCompleted && !completed && !code.isEmpty {
                    guard !data.records.contains(where: {
                        $0.id != previous.id && $0.groupID == previous.groupID && !$0.isCompleted &&
                        $0.code.trimmingCharacters(in: .whitespacesAndNewlines) == code
                    }) else { throw PickupStorageError.invalidData("此分组已有未完成的相同取码。") }
                }
                data.records[linked].isCompleted = completed
            }
            data.records[linked].updatedAt = current.updatedAt
            data.shipments[index] = current
            return oldStatus != .delivered && current.status == .delivered
        }
        reloadWidgets()
        return delivered
        } catch {
            // Never replace the original exception if recording the safe diagnostic fails.
            // No data transaction/lock spans the network await.
            if !(error is CancellationError), (error as? UAPIError) != .cancelled {
                try? store.transaction { data in
                    guard let index = data.shipments.firstIndex(where: { $0.id == id }),
                          Self.sameIdentity(data.shipments[index], before),
                          data.shipments[index].status == before.status,
                          data.shipments[index].lastQueriedAt == before.lastQueriedAt,
                          data.shipments[index].logisticsTime == before.logisticsTime,
                          data.shipments[index].logisticsSource == before.logisticsSource,
                          let linkedID,
                          data.records.contains(where: { $0.id == linkedID && $0.shipmentID == id }) else { return }
                    data.shipments[index].lastRefreshError = Self.safeReason(error)
                }
                reloadWidgets()
            }
            throw error
        }
    }
    func refreshPending(mode: TrackingRefreshMode = .automatic) async throws -> TrackingRefreshReport {
        let ids = try store.snapshot().shipments.filter(Self.isPending).sorted {
            let left = $0.lastQueryAttemptAt ?? $0.lastQueriedAt ?? .distantPast
            let right = $1.lastQueryAttemptAt ?? $1.lastQueriedAt ?? .distantPast
            return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
        }.map(\.id)
        var report = TrackingRefreshReport()
        let started = uptime()
        var platformStopped = false
        for (offset, id) in ids.enumerated() {
            try Task.checkCancellation()
            // Do not run an unbounded network loop inside a Shortcuts invocation.
            if uptime() - started >= 20 {
                report.remaining = ids.count - offset
                report.stoppedReason = "本轮执行时间已到，请再次运行以继续刷新。"
                break
            }
            // Recheck before each request; another process may have completed/deleted it.
            guard let latest = try store.snapshot().shipments.first(where: { $0.id == id }), Self.isPending(latest) else { continue }
            if mode == .platformOnly, !Self.isTaobao(latest) { report.skipped += 1; continue }
            let route = try? Self.route(latest, mode: mode)
            if platformStopped, route == .taobao { report.skipped += 1; continue }
            do {
                // Persist only scheduling metadata before awaiting; shared across invocations.
                let shouldQuery = try store.transaction { data -> Bool in
                    guard let index = data.shipments.firstIndex(where: { $0.id == id }),
                          Self.isPending(data.shipments[index]),
                          data.shipments[index].trackingNumber == latest.trackingNumber else { return false }
                    data.shipments[index].lastQueryAttemptAt = Date()
                    return true
                }
                guard shouldQuery else { continue }
                if route == .taobao { report.taobaoCount += 1 }
                if route == .uapi { report.uapiCount += 1 }
                if try await refresh(id: id, expectedTrackingNumber: CarrierDetector.sanitize(latest.trackingNumber), pendingOnly: true, mode: mode) { report.newlyDelivered += 1 }
                report.succeeded += 1
            } catch is CancellationError { throw CancellationError() }
            catch UAPIError.cancelled { throw UAPIError.cancelled }
            catch {
                let reason = Self.safeReason(error)
                if let failure = error as? TaobaoTrackingError, failure.stopsBatch {
                    platformStopped = true
                    report.stoppedReason = reason
                }
                let number = (try? ShipmentShortcutParser.number(latest.trackingNumber)) ?? "无效运单号"
                report.failures.append(.init(trackingNumber: number, reason: reason))
                if let failure = error as? UAPIError, failure.stopsBatch {
                    report.remaining = ids.count - offset - 1
                    report.stoppedReason = failure.localizedDescription
                    break
                }
            }
        }
        return report
    }
}
