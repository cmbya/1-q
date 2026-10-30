import Foundation
import WidgetKit

struct TrackingRefreshReport {
    var succeeded = 0
    var failed = 0
    var newlyDelivered = 0
    var remaining = 0
    var stoppedReason: String?
    var message: String {
        var value = "更新成功 \(succeeded) 票，失败 \(failed) 票，新增签收 \(newlyDelivered) 票，未处理 \(remaining) 票。"
        if let stoppedReason { value += " \(stoppedReason)" }
        return value
    }
}

/// App buttons and AppIntents share this service. Network awaits never hold flock.
struct TrackingRefreshService {
    let store: SharedPickupStore
    let client: any UAPITrackingQuerying
    var reloadWidgets: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    static func live() throws -> TrackingRefreshService {
        TrackingRefreshService(store: try SharedPickupStore(appGroupID: nil, accessMode: .existingSharedData), client: UAPITrackingClient())
    }
    static func isPending(_ shipment: Shipment) -> Bool {
        shipment.status != .delivered && shipment.status != .archived
    }
    func refresh(trackingNumber: String, phone: String? = nil) async throws -> Bool {
        let number = try ShipmentShortcutParser.number(trackingNumber)
        let matches = try store.snapshot().shipments.filter { CarrierDetector.sanitize($0.trackingNumber) == number }
        guard matches.count == 1, let shipment = matches.first else {
            if matches.isEmpty { throw PickupStorageError.notFound }
            throw ShipmentShortcutError.ambiguous
        }
        return try await refresh(id: shipment.id, phone: phone)
    }
    /// Returns whether this update newly completed a shipment.
    func refresh(id: UUID, phone: String? = nil) async throws -> Bool {
        try Task.checkCancellation()
        guard let before = try store.snapshot().shipments.first(where: { $0.id == id }) else { throw PickupStorageError.notFound }
        guard before.status != .archived else { throw ShipmentShortcutError.statusConflict }
        let number = try ShipmentShortcutParser.number(before.trackingNumber)
        let result = try await client.query(trackingNumber: number, carrierCode: before.uapiCarrierCode, phone: phone, refresh: true)
        try Task.checkCancellation()
        guard result.trackingNumber == number else { throw UAPIError.invalidResponse }
        let delivered = try store.transaction { data -> Bool in
            guard let index = data.shipments.firstIndex(where: { $0.id == id }),
                  CarrierDetector.sanitize(data.shipments[index].trackingNumber) == number else { throw PickupStorageError.notFound }
            var current = data.shipments[index]
            guard current.status != .archived else { throw ShipmentShortcutError.statusConflict }
            if let old = current.logisticsTime {
                guard let incoming = result.logisticsTime, incoming >= old else { throw ShipmentShortcutError.olderUpdate }
            }
            if let queried = current.lastQueriedAt, result.queriedAt < queried { throw ShipmentShortcutError.olderUpdate }
            if current.status == .delivered, let state = result.status, state != .delivered { throw ShipmentShortcutError.statusConflict }
            guard let linked = data.records.firstIndex(where: { $0.shipmentID == id }) else { throw PickupStorageError.invalidData("运单关联记录缺失") }
            let oldStatus = current.status
            current.logisticsInfo = result.logisticsInfo
            current.logisticsTime = result.logisticsTime
            current.queryInfo = result.queryInfo
            current.lastQueriedAt = result.queriedAt
            if !result.carrierName.isEmpty { current.carrierName = result.carrierName }
            if !result.carrierCode.isEmpty { current.uapiCarrierCode = result.carrierCode }
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
    }
    func refreshPending() async throws -> TrackingRefreshReport {
        let ids = try store.snapshot().shipments.filter(Self.isPending).sorted {
            let left = $0.lastQueriedAt ?? .distantPast
            let right = $1.lastQueriedAt ?? .distantPast
            return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
        }.map(\.id)
        var report = TrackingRefreshReport()
        let started = ProcessInfo.processInfo.systemUptime
        for (offset, id) in ids.enumerated() {
            try Task.checkCancellation()
            // Do not run an unbounded network loop inside a Shortcuts invocation.
            if ProcessInfo.processInfo.systemUptime - started >= 20 {
                report.remaining = ids.count - offset
                report.stoppedReason = "本轮执行时间已到，请再次运行以继续刷新。"
                break
            }
            // Recheck before each request; another process may have completed/deleted it.
            guard let latest = try store.snapshot().shipments.first(where: { $0.id == id }), Self.isPending(latest) else { continue }
            do {
                if try await refresh(id: id) { report.newlyDelivered += 1 }
                report.succeeded += 1
            } catch is CancellationError { throw CancellationError() }
            catch UAPIError.cancelled { throw UAPIError.cancelled }
            catch {
                report.failed += 1
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
