import Foundation
import WidgetKit

enum TrackingRefreshMode: String, Codable, CaseIterable {
    case automatic, platformOnly, uapi, tmini
}

struct TrackingRefreshReport {
    var succeeded = 0
    var skipped = 0
    /// Number of tickets dispatched to each source (successes and failures).
    var taobaoCount = 0
    var uapiCount = 0
    var tminiCount = 0
    var cachedCount = 0
    var jdCount = 0
    var pddCount = 0
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
        value += " 淘宝派发\(taobaoCount)票，京东派发\(jdCount)票，拼多多派发\(pddCount)票，UAPI派发\(uapiCount)票（实际收费以接口为准）。"
        value += " Tmini派发\(tminiCount)票（付费渠道）。"
        if cachedCount > 0 { value += " 本地缓存命中 \(cachedCount) 票（未联网、未新增收费）。" }
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
    var tminiClient: any TminiTrackingQuerying = TminiTrackingClient()
    var reloadWidgets: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var phones = ShipmentPhoneStore()
    var taobaoClient: any TaobaoTrackingQuerying = TaobaoTrackingClient()

    var mallClient: any MallTrackingQuerying = MallTrackingClient()

    private enum Route: Equatable {
        case taobao, uapi, tmini, mall(String)
        var platform: String? {
            switch self {
            case .taobao: return "taobao"
            case .mall(let platform): return platform
            case .uapi, .tmini: return nil
            }
        }
        var source: String { self == .tmini ? "tmini" : (platform ?? "uapi") }
    }
    private static func platformRoute(_ shipment: Shipment) throws -> Route {
        if shipment.originPlatform == "jd" { throw RemovedJDTrackingError.removed }
        if shipment.originPlatform == "pdd" { return .mall("pdd") }
        if isTaobao(shipment) { return .taobao }
        throw TaobaoTrackingError.unsupported
    }
    private static func isTaobao(_ shipment: Shipment) -> Bool {
        shipment.originPlatform == "taobao" || shipment.taobaoOrderID != nil
    }
    private static func route(_ shipment: Shipment, mode: TrackingRefreshMode) throws -> Route {
        if mode == .uapi { return .uapi }
        if mode == .tmini { return .tmini }
        if mode == .platformOnly { return try platformRoute(shipment) }
        if shipment.refreshChannel == "uapi" { return .uapi }
        if shipment.refreshChannel == "tmini" { return .tmini }
        guard shipment.refreshChannel == nil else { throw TaobaoTrackingError.unsupported }
        if shipment.originPlatform == "jd" { throw RemovedJDTrackingError.removed }
        if shipment.originPlatform == "pdd" { return .mall("pdd") }
        if isTaobao(shipment) { return .taobao }
        // Missing origin is the legacy/manual UAPI path, not a platform fallback.
        guard shipment.originPlatform == nil || shipment.originPlatform == "manual" || shipment.originPlatform == "uapi" else {
            throw TaobaoTrackingError.unsupported
        }
        return .uapi
    }
    func setRefreshChannel(id: UUID, channel: String?) throws {
        guard channel == nil || channel == "uapi" || channel == "tmini" else { throw TaobaoTrackingError.unsupported }
        let lease = try store.acquireTrackingQuery(id: id)
        defer { lease.release() }
        try store.transaction { data in
            guard let index = data.shipments.firstIndex(where: { $0.id == id }) else { throw PickupStorageError.notFound }
            data.shipments[index].refreshChannel = channel
        }
        reloadWidgets()
    }

    private static func safeReason(_ error: Error, platform: String? = nil) -> String {
        if let failure = error as? PaidTrackingCacheError { return failure.localizedDescription }
        if let failure = error as? TminiError { return failure.localizedDescription }
        if let terminal = error as? KDYZMTerminalResultError { return terminal.localizedDescription }
        if let backend = error as? KDYZMError { return backend.localizedDescription }
        if let failure = error as? RemovedJDTrackingError { return failure.localizedDescription }
        if let direct = error as? MallDirectError { return direct.localizedDescription }
        if let platform, platform == "jd" || platform == "pdd" {
            let name = platform == "jd" ? "京东" : "拼多多"
            let detail: String
            if let failure = error as? MallWebError {
                switch failure {
                case .authentication: detail = "登录已失效，请在 App 重新登录。"
                case .verification: detail = "需要验证，请在 App 完成验证。"
                case .unsupported: detail = "订单关联或页面格式不受支持，请重新绑定并检查。"
                case .identityMismatch: detail = "订单或运单身份不匹配，未更新。"
                case .noTrace: detail = "暂无可用物流轨迹，保留上次结果。"
                case .timeout: detail = "页面查询超时，请稍后重试。"
                }
            } else { detail = safeReason(error) }
            return "\(name)物流刷新：\(detail)"
        }
        if let failure = error as? TaobaoTrackingError {
            switch failure {
            case .missingBinding: return "淘宝订单关联缺失，请重新绑定后刷新。"
            case .unsupported: return failure.localizedDescription
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
        current.platformOrderID == before.platformOrderID && current.platformLogisticsURL == before.platformLogisticsURL &&
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
    static func live(ignoreCache: Bool = false) throws -> TrackingRefreshService {
        TrackingRefreshService(store: try SharedPickupStore(appGroupID: nil, accessMode: .existingSharedData), client: UAPITrackingClient(ignoreCache: ignoreCache), tminiClient: TminiTrackingClient(ignoreCache: ignoreCache))
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
    func refresh(id: UUID, phone: String? = nil, expectedTrackingNumber: String? = nil, pendingOnly: Bool = false, mode: TrackingRefreshMode = .automatic, cacheFeedback: (Bool) -> Void = { _ in }) async throws -> Bool {
        // Resolve backend before the legacy lease: no lease spans backend networking.
        // Explicit UAPI override is honored, but backend failures never fall back to it.
        if let before = try store.snapshot().shipments.first(where: { $0.id == id }),
           before.backendBinding != nil, mode != .uapi, mode != .tmini,
           mode == .platformOnly || before.refreshChannel == nil {
            guard before.status != .archived, !pendingOnly || Self.isPending(before) else { throw ShipmentShortcutError.statusConflict }
            if let expectedTrackingNumber, CarrierDetector.sanitize(before.trackingNumber) != expectedTrackingNumber { throw KDYZMError.stale }
            let operation = UUID()
            DiagnosticLog.shared.record(.trackingStarted, operation: operation)
            do {
                let result = try await KDYZMRefreshService(store: store, reloadWidgets: reloadWidgets).refresh(before: before)
                DiagnosticLog.shared.record(.trackingFinished, operation: operation)
                return result
            } catch {
                // Store only fixed, safe messages, never transport/server strings or secrets.
                DiagnosticLog.shared.record(.trackingFailed, operation: operation, reason: .unknown)
                if !(error is CancellationError) {
                    if let lease = try? store.acquireTrackingQuery(id: id) {
                    defer { lease.release() }
                    try? store.transaction { data in
                        guard let index = data.shipments.firstIndex(where: { $0.id == id }),
                              KDYZMMerger.sameIdentity(data.shipments[index], before),
                              data.shipments[index].status == before.status,
                              data.shipments[index].lastQueriedAt == before.lastQueriedAt,
                              data.shipments[index].logisticsTime == before.logisticsTime,
                              data.shipments[index].logisticsSource == before.logisticsSource else { return }
                        if let terminal = error as? KDYZMTerminalResultError {
                            data.shipments[index].lastRefreshError = terminal.localizedDescription
                        } else {
                            data.shipments[index].lastRefreshError = KDYZMError.safe(error)
                        }
                    }
                    }
                    reloadWidgets()
                }
                throw error
            }
        }
        let logID = UUID()
        DiagnosticLog.shared.record(.trackingStarted, operation: logID)
        var logSucceeded = false
        defer { DiagnosticLog.shared.record(logSucceeded ? .trackingFinished : .trackingFailed, operation: logID, reason: logSucceeded ? nil : .unknown) }
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
        var tminiConfiguration: TminiConfiguration?
        switch route {
        case .taobao:
            guard let orderID = before.taobaoOrderID, !orderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TaobaoTrackingError.missingBinding
            }
            result = try await taobaoClient.query(orderID: orderID, trackingNumber: number)
        case .mall(let platform):
            guard let orderID = before.platformOrderID,
                  Shipment.validPlatformOrderID(orderID, platform: platform) else { throw MallWebError.unsupported }
            result = try await mallClient.query(platform: platform, orderID: orderID, trackingNumber: number, sourceURL: before.platformLogisticsURL.flatMap { Shipment.logisticsEntry($0, orderID: orderID) })
        case .tmini:
            tminiConfiguration = try tminiClient.configurationToken()
            result = try await tminiClient.query(trackingNumber: number)
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
        cacheFeedback(result.isCached)
        try Task.checkCancellation()
        guard result.trackingNumber == number else {
            if route == .taobao { throw TaobaoTrackingError.identityMismatch }
            if case .mall = route { throw MallWebError.identityMismatch }
            if route == .tmini { throw TminiError.invalidResponse }
            throw UAPIError.invalidResponse
        }
        let delivered = try store.transaction { data -> Bool in
            if let tminiConfiguration { try tminiClient.validateConfiguration(tminiConfiguration) }
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
            current.logisticsSource = route.source
            current.lastRefreshError = nil
            if let state = result.status { current.status = state }
            current.updatedAt = Date()
            // Logistics may complete a pending record, never undo manual collection.
            // Reopening remains an explicit user action through setPickupCompleted.
            if current.status != oldStatus, current.status == .delivered {
                data.records[linked].isCompleted = true
            }
            data.records[linked].updatedAt = current.updatedAt
            data.shipments[index] = current
            return oldStatus != .delivered && current.status == .delivered
        }
        reloadWidgets()
        logSucceeded = true
        return delivered
        } catch {
            // Never replace the original exception if recording the safe diagnostic fails.
            // No data transaction/lock spans the network await.
            if !(error is CancellationError), (error as? UAPIError) != .cancelled, (error as? TminiError) != .cancelled {
                try? store.transaction { data in
                    guard let index = data.shipments.firstIndex(where: { $0.id == id }),
                          Self.sameIdentity(data.shipments[index], before),
                          data.shipments[index].status == before.status,
                          data.shipments[index].lastQueriedAt == before.lastQueriedAt,
                          data.shipments[index].logisticsTime == before.logisticsTime,
                          data.shipments[index].logisticsSource == before.logisticsSource,
                          let linkedID,
                          data.records.contains(where: { $0.id == linkedID && $0.shipmentID == id }) else { return }
                    data.shipments[index].lastRefreshError = Self.safeReason(error, platform: (try? Self.route(before, mode: mode))?.platform ?? before.originPlatform)
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
        var blockedPlatforms: Set<String> = []
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
            if mode == .platformOnly, latest.originPlatform != "jd", (try? Self.platformRoute(latest)) == nil { report.skipped += 1; continue }
            let route = try? Self.route(latest, mode: mode)
            if route == .tmini, blockedPlatforms.contains("tmini") { report.skipped += 1; continue }
            if let platform = route?.platform, blockedPlatforms.contains(platform) { report.skipped += 1; continue }
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
                if route == .tmini { report.tminiCount += 1 }
                if route == .mall("jd") || (latest.backendBinding != nil && mode != .uapi && mode != .tmini && (mode == .platformOnly || latest.refreshChannel == nil)) { report.jdCount += 1 }
                if route == .mall("pdd") { report.pddCount += 1 }
                if try await refresh(id: id, expectedTrackingNumber: CarrierDetector.sanitize(latest.trackingNumber), pendingOnly: true, mode: mode, cacheFeedback: { cached in
                    if cached {
                        report.cachedCount += 1
                        if route == .uapi { report.uapiCount -= 1 }
                        if route == .tmini { report.tminiCount -= 1 }
                    }
                }) { report.newlyDelivered += 1 }
                report.succeeded += 1
            } catch is CancellationError { throw CancellationError() }
            catch UAPIError.cancelled { throw UAPIError.cancelled }
            catch TminiError.cancelled { throw TminiError.cancelled }
            catch {
                let reason = Self.safeReason(error, platform: route?.platform ?? latest.originPlatform)
                if let failure = error as? TminiError, failure.stopsBatch {
                    blockedPlatforms.insert("tmini")
                    report.stoppedReason = reason
                }
                if let failure = error as? TaobaoTrackingError, failure.stopsBatch {
                    blockedPlatforms.insert("taobao")
                    report.stoppedReason = reason
                }
                if let failure = error as? MallDirectError, failure.reason.stopsBatch, let platform = route?.platform {
                    blockedPlatforms.insert(platform)
                    report.stoppedReason = reason
                }
                if let failure = error as? MallWebError, failure.stopsBatch, let platform = route?.platform {
                    blockedPlatforms.insert(platform)
                    report.stoppedReason = reason
                }
                let number = (try? ShipmentShortcutParser.number(latest.trackingNumber)) ?? "无效运单号"
                report.failures.append(.init(trackingNumber: number, reason: reason))
                if error is PaidTrackingCacheError {
                    report.remaining = ids.count - offset - 1
                    report.stoppedReason = reason
                    break
                }
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
