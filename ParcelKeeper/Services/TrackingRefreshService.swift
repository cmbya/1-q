import Foundation
import WidgetKit

enum TrackingChannelError: LocalizedError, Equatable {
    case unsupported, directImportDisabled
    var errorDescription: String? {
        switch self {
        case .unsupported: return "此运单不支持当前查询渠道，请检查来源或手动选择 UAPI／Tmini。"
        case .directImportDisabled: return "当前版本已停用淘宝／拼多多直连导入和刷新。历史记录已保留，可绑定取件助手后台或手动选择 UAPI／Tmini。"
        }
    }
}

enum TrackingRefreshMode: String, Codable, CaseIterable {
    case automatic, platformOnly, uapi, tmini
}

struct TrackingRefreshReport {
    var succeeded = 0
    var skipped = 0
    /// Tickets attempted by route, including local preflight failures.
    /// Compatibility field names, not actual HTTP request/billing counters.
    var taobaoCount = 0
    var uapiCount = 0
    var tminiCount = 0
    var cachedCount = 0
    var backendCount = 0
    var pddCount = 0
    struct Failure {
        let trackingNumber: String
        let reason: String
    }
    var failures: [Failure] = []
    var queued: [Failure] = []
    var failed: Int { failures.count }
    var newlyDelivered = 0
    var remaining = 0
    var stoppedReason: String?
    var message: String {
        var value = "更新成功 \(succeeded) 票，失败 \(failed) 票，新增签收 \(newlyDelivered) 票，未处理 \(remaining) 票。"
        value += " 按渠道尝试票数：取件助手后台\(backendCount)票，淘宝\(taobaoCount)票，拼多多\(pddCount)票，UAPI\(uapiCount)票，Tmini\(tminiCount)票。"
        value += " 包含本地预检失败，不代表实际网络请求或收费次数；付费以接口实际计费为准。"
        if cachedCount > 0 { value += " 本地缓存命中 \(cachedCount) 票（未联网、未新增收费）。" }
        if skipped > 0 { value += " 跳过 \(skipped) 票。" }
        if let stoppedReason { value += " \(stoppedReason)" }
        for failure in failures { value += "\n\(failure.trackingNumber)：\(failure.reason)" }
        if !queued.isEmpty { value += " 后台处理中／排队 \(queued.count) 票（不计失败）。" }
        for pending in queued { value += "\n\(pending.trackingNumber)：\(pending.reason)" }
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
#if ENABLE_DIRECT_MALL_IMPORT
    var taobaoClient: any TaobaoTrackingQuerying = TaobaoTrackingClient()

    var mallClient: any MallTrackingQuerying = MallTrackingClient()
#endif
    var backendConnection: KDYZMConnection = .shared
    var backendClient = KDYZMClient()
    var diagnosticLog: DiagnosticLog = .shared

    private enum Route: Equatable {
        case backend
        case taobao, uapi, tmini, mall(String)
        var platform: String? {
            switch self {
            case .taobao: return "taobao"
            case .mall(let platform): return platform
            case .backend, .uapi, .tmini: return nil
            }
        }
        var source: String { self == .backend ? "kdyzm" : (self == .tmini ? "tmini" : (platform ?? "uapi")) }
    }
    private static func platformRoute(_ shipment: Shipment) throws -> Route {
        if shipment.originPlatform == "pdd" { return .mall("pdd") }
        if isTaobao(shipment) { return .taobao }
        throw TrackingChannelError.unsupported
    }
    private static func isTaobao(_ shipment: Shipment) -> Bool {
        shipment.originPlatform == "taobao" || shipment.taobaoOrderID != nil
    }
    private static func route(_ shipment: Shipment, mode: TrackingRefreshMode) throws -> Route {
        if mode == .uapi { return .uapi }
        if mode == .tmini { return .tmini }
        if shipment.backendBinding != nil, mode == .platformOnly || shipment.refreshChannel == nil { return .backend }
        if mode == .platformOnly { return try platformRoute(shipment) }
        if shipment.refreshChannel == "uapi" { return .uapi }
        if shipment.refreshChannel == "tmini" { return .tmini }
        guard shipment.refreshChannel == nil else { throw TrackingChannelError.unsupported }
        if shipment.originPlatform == "pdd" { return .mall("pdd") }
        if isTaobao(shipment) { return .taobao }
        // Missing origin is the legacy/manual UAPI path, not a platform fallback.
        guard shipment.originPlatform == nil || shipment.originPlatform == "manual" || shipment.originPlatform == "uapi" else {
            throw TrackingChannelError.unsupported
        }
        return .uapi
    }
    static func resolvedChannel(_ shipment: Shipment, mode: TrackingRefreshMode = .automatic) throws -> String {
        try route(shipment, mode: mode).source
    }
    static func routingDiagnostics(_ shipment: Shipment, mode: TrackingRefreshMode) -> [DiagnosticMetric: Int] {
        [.hasBackendBinding: shipment.backendBinding == nil ? 0 : 1,
         .explicitPaidChannel: ["uapi", "tmini"].contains(shipment.refreshChannel ?? "") ? 1 : 0,
         .forcedPaidMode: mode == .uapi || mode == .tmini ? 1 : 0]
    }
    private static func routeEvent(_ route: Route) -> DiagnosticEvent {
        switch route {
        case .backend: return .trackingRouteBackend
        case .taobao: return .trackingRouteTaobao
        case .tmini: return .trackingRouteTmini
        case .uapi: return .trackingRouteUAPI
        case .mall: return .trackingRoutePDD
        }
    }
    static func diagnosticReason(_ error: Error) -> DiagnosticReason {
        if error is CancellationError { return .cancelled }
        if error is TrackingChannelError { return .unsupported }
        if let failure = error as? KDYZMTerminalResultError { return failure.originalReason }
        if let failure = error as? TrackingTimeRejection { return failure.reason }
        if let failure = error as? KDYZMSyncFailure {
            switch failure {
            case .decoding: return .parse
            case .validation: return .validation
            case .association: return .association
            case .localRead, .localWrite, .presentation: return .storage
            }
        }
        if error is PaidTrackingCacheError { return .storage }
#if ENABLE_DIRECT_MALL_IMPORT
        if let failure = error as? MallDirectError { return diagnosticReason(failure.reason) }
        if let failure = error as? MallWebError {
            switch failure {
            case .authentication: return .authentication
            case .verification: return .verification
            case .identityMismatch: return .identity
            case .noTrace: return .noTrace
            case .timeout: return .timeout
            case .unsupported: return .unsupported
            }
        }
        if let failure = error as? TaobaoTrackingError {
            switch failure {
            case .authentication: return .authentication
            case .verification: return .verification
            case .identityMismatch, .missingBinding: return .identity
            case .noTrace: return .noTrace
            case .unsupported: return .unsupported
            }
        }
#endif
        if let failure = error as? ShipmentShortcutError {
            switch failure {
            case .olderUpdate: return .olderEvent
            case .statusConflict: return .statusConflict
            default: return .identity
            }
        }
        if let failure = error as? KDYZMError {
            switch failure {
            case .queued: return .queued
            case .unauthorized, .forbidden: return .authentication
            case .stale: return .identity
            case .empty: return .noTrace
            case .network: return .network
            case .rateLimited: return .rateLimited
            case .keychain: return .storage
            case .origin, .pairing, .alreadyBound: return .configuration
            case .invalid: return .parse
            case .failed: return .unavailable
            case .jobGone: return .jobGone
            }
        }
        if let failure = error as? TminiError {
            switch failure {
            case .configurationChanged: return .configurationChanged
            case .authentication: return .authentication
            case .notConfigured, .consent, .invalidKey: return .configuration
            case .cancelled: return .cancelled
            case .quota: return .quota
            case .rateLimited: return .rateLimited
            case .accounting: return .accounting
            case .keychain: return .storage
            case .noData: return .noTrace
            case .invalidResponse: return .parse
            case .invalidNumber: return .identity
            case .maintenance: return .unavailable
            case .unavailable: return .network
            }
        }
        if let failure = error as? UAPIError {
            switch failure {
            case .configurationChanged: return .configurationChanged
            case .authentication: return .authentication
            case .notConfigured, .privacyConsentRequired, .invalidKey: return .configuration
            case .quota: return .quota
            case .rateLimited: return .rateLimited
            case .noData: return .noTrace
            case .invalidResponse: return .parse
            case .invalidPhone, .invalidTrackingNumber: return .identity
            case .keychain: return .storage
            case .unavailable: return .network
            case .cancelled: return .cancelled
            }
        }
        if let failure = error as? PickupStorageError {
            switch failure {
            case .queryInProgress: return .busy
            case .stalePreview, .notFound: return .identity
            default: return .storage
            }
        }
        if let failure = error as? URLError { return failure.code == .cancelled ? .cancelled : (failure.code == .timedOut ? .timeout : .network) }
        if error is POSIXError { return .storage }
        return .unknown
    }
    func setRefreshChannel(id: UUID, channel: String?) throws {
        guard channel == nil || channel == "uapi" || channel == "tmini" else { throw TrackingChannelError.unsupported }
        let lease = try store.acquireTrackingQuery(id: id)
        defer { lease.release() }
        try store.transaction { data in
            guard let index = data.shipments.firstIndex(where: { $0.id == id }) else { throw PickupStorageError.notFound }
            data.shipments[index].refreshChannel = channel
        }
        reloadWidgets()
    }

    private static func safeReason(_ error: Error, platform: String? = nil) -> String {
        if let failure = error as? TrackingChannelError { return failure.localizedDescription }
        if let failure = error as? TrackingTimeRejection { return failure.localizedDescription }
        if let failure = error as? PaidTrackingCacheError { return failure.localizedDescription }
        if let failure = error as? TminiError { return failure.localizedDescription }
        if let terminal = error as? KDYZMTerminalResultError { return terminal.localizedDescription }
        if let backend = error as? KDYZMError { return backend.localizedDescription }
#if ENABLE_DIRECT_MALL_IMPORT
        if let direct = error as? MallDirectError { return direct.localizedDescription }
        if let platform, platform == "pdd" {
            let name = "拼多多"
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
#endif
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
    static func live(ignoreCache _: Bool = false) throws -> TrackingRefreshService {
        TrackingRefreshService(store: try SharedPickupStore(appGroupID: nil, accessMode: .existingSharedData), client: UAPITrackingClient(), tminiClient: TminiTrackingClient())
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
        let logID = UUID()
        diagnosticLog.record(.trackingStarted, operation: logID)
        let trace = DiagnosticTrace(operation: logID, log: diagnosticLog)
        trace.begin(.preflight)
        do {
            let result = try await performRefresh(id: id, phone: phone, expectedTrackingNumber: expectedTrackingNumber, pendingOnly: pendingOnly, mode: mode, cacheFeedback: cacheFeedback, logID: logID, trace: trace)
            trace.finish()
            diagnosticLog.record(.trackingFinished, operation: logID)
            return result
        } catch {
            let terminal = error as? KDYZMTerminalResultError
            let stage = terminal?.originalStage ?? trace.failureStage ?? trace.stage ?? .preflight
            trace.fail(error)
            diagnosticLog.record(.trackingFailed, operation: logID, reason: Self.diagnosticReason(error), stage: stage)
            throw error
        }
    }
    private func performRefresh(id: UUID, phone: String?, expectedTrackingNumber: String?, pendingOnly: Bool, mode: TrackingRefreshMode, cacheFeedback: (Bool) -> Void, logID: UUID, trace: DiagnosticTrace) async throws -> Bool {
        try Task.checkCancellation()
        trace.begin(.localRead)
        // Resolve backend before the legacy lease: no lease spans backend networking.
        // Explicit UAPI override is honored, but backend failures never fall back to it.
        if let before = try store.snapshot().shipments.first(where: { $0.id == id }),
           (try? Self.route(before, mode: mode)) == .backend {
            guard before.status != .archived, !pendingOnly || Self.isPending(before) else { throw ShipmentShortcutError.statusConflict }
            if let expectedTrackingNumber, CarrierDetector.sanitize(before.trackingNumber) != expectedTrackingNumber { throw KDYZMError.stale }
            diagnosticLog.record(.trackingRouteBackend, operation: logID, counts: Self.routingDiagnostics(before, mode: mode))
            do {
                trace.finish()
                let result = try await KDYZMRefreshService(store: store, connection: backendConnection, client: backendClient, reloadWidgets: reloadWidgets).refresh(before: before, operation: logID, trace: trace)
                return result
            } catch {
                // Store only fixed, safe messages, never transport/server strings or secrets.
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
        try Task.checkCancellation()
        trace.begin(.lease)
        let lease = try store.acquireTrackingQuery(id: id)
        defer { lease.release() }
        trace.begin(.localRead)
        let snapshot = try store.snapshot()
        guard let before = snapshot.shipments.first(where: { $0.id == id }) else { throw PickupStorageError.notFound }
        guard before.status != .archived else { throw ShipmentShortcutError.statusConflict }
        guard !pendingOnly || Self.isPending(before) else { throw ShipmentShortcutError.statusConflict }
        let number = try ShipmentShortcutParser.number(before.trackingNumber)
        if let expectedTrackingNumber, number != expectedTrackingNumber { throw PickupStorageError.stalePreview }
        let linkedID = snapshot.records.first(where: { $0.shipmentID == id })?.id
#if ENABLE_DIRECT_MALL_IMPORT
        var mallGeneration: (platform: MallPlatform, expected: UUID)?
#endif
        var uapiConfiguration: UAPIConfiguration?
        // Generation guard outside dataset transaction, never across await.
        func commitResult<T>(_ operation: () throws -> T) throws -> T {
#if ENABLE_DIRECT_MALL_IMPORT
            if let mallGeneration {
                return try MallSession.withGeneration(platform: mallGeneration.platform, expected: mallGeneration.expected, operation: operation)
            }
#endif
            if let uapiConfiguration {
                return try client.withConfiguration(uapiConfiguration, operation: operation)
            }
            return try operation()
        }
        do {
        let route = try Self.route(before, mode: mode)
        diagnosticLog.record(Self.routeEvent(route), operation: logID, counts: Self.routingDiagnostics(before, mode: mode))
        let result: UAPITrackingResult
        var tminiConfiguration: TminiConfiguration?
        trace.begin(.request)
        switch route {
        case .backend:
            // Backend dispatch must happen before acquiring the legacy lease.
            throw KDYZMError.stale
#if ENABLE_DIRECT_MALL_IMPORT
        case .taobao:
            guard let orderID = before.taobaoOrderID, !orderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TaobaoTrackingError.missingBinding
            }
            result = try await taobaoClient.query(orderID: orderID, trackingNumber: number)
        case .mall(let platform):
            guard let orderID = before.platformOrderID,
                  Shipment.validPlatformOrderID(orderID, platform: platform),
                  let mallPlatform = MallPlatform(rawValue: platform) else { throw MallWebError.unsupported }
            mallGeneration = (mallPlatform, MallSession.generation(for: mallPlatform))
            result = try await mallClient.query(platform: platform, orderID: orderID, trackingNumber: number)
#else
        case .taobao, .mall:
            throw TrackingChannelError.directImportDisabled
#endif
        case .tmini:
            tminiConfiguration = try tminiClient.configurationToken()
            result = try await tminiClient.query(trackingNumber: number)
        case .uapi:
        uapiConfiguration = try client.configurationToken()
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
        trace.begin(.response)
        cacheFeedback(result.isCached)
        try Task.checkCancellation()
        guard result.trackingNumber == number else {
#if ENABLE_DIRECT_MALL_IMPORT
            if route == .taobao { throw TaobaoTrackingError.identityMismatch }
            if case .mall = route { throw MallWebError.identityMismatch }
#endif
            if route == .tmini { throw TminiError.invalidResponse }
            throw UAPIError.invalidResponse
        }
        trace.begin(.merge)
        let delivered = try commitResult {
        try store.transaction { data -> Bool in
            if let tminiConfiguration { try tminiClient.validateConfiguration(tminiConfiguration) }
            guard let index = data.shipments.firstIndex(where: { $0.id == id }),
                  CarrierDetector.sanitize(data.shipments[index].trackingNumber) == number else { throw PickupStorageError.notFound }
            var current = data.shipments[index]
            guard Self.sameIdentity(current, before) else { throw PickupStorageError.stalePreview }
            guard current.status != .archived else { throw ShipmentShortcutError.statusConflict }
            // Apply this response without comparing its event/query times to saved data.
            if current.status == .delivered, let state = result.status, state != .delivered { throw ShipmentShortcutError.statusConflict }
            guard let linked = data.records.firstIndex(where: { $0.shipmentID == id }),
                  data.records[linked].id == linkedID else { throw PickupStorageError.invalidData("运单关联记录缺失或已改变") }
            let oldStatus = current.status
            current.logisticsInfo = result.logisticsInfo
            current.logisticsTime = result.logisticsTime
            current.queryInfo = TrackingQueryHistory.merged(result.queryInfo, current.queryInfo, current.backendPreviousHistory)
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
            trace.begin(.save)
            return oldStatus != .delivered && current.status == .delivered
        }
        }
        reloadWidgets()
        return delivered
        } catch {
            // Never replace the original exception if recording the safe diagnostic fails.
            // No data transaction/lock spans the network await.
            if !(error is CancellationError), (error as? UAPIError) != .cancelled, (error as? TminiError) != .cancelled {
                try? commitResult {
                try store.transaction { data in
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
            let route = try? Self.route(latest, mode: mode)
            if mode == .platformOnly, route == nil { report.skipped += 1; continue }
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
                if route == .backend { report.backendCount += 1 }
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
            catch KDYZMError.queued {
                let number = (try? ShipmentShortcutParser.number(latest.trackingNumber)) ?? "无效运单号"
                report.queued.append(.init(trackingNumber: number, reason: KDYZMError.queued.localizedDescription))
            }
            catch UAPIError.cancelled { throw UAPIError.cancelled }
            catch TminiError.cancelled { throw TminiError.cancelled }
            catch {
                let reason = Self.safeReason(error, platform: route?.platform ?? latest.originPlatform)
                if let failure = error as? TminiError, failure.stopsBatch {
                    blockedPlatforms.insert("tmini")
                    report.stoppedReason = reason
                }
#if ENABLE_DIRECT_MALL_IMPORT
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
#endif

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
