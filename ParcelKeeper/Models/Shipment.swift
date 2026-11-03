import Foundation

// Value-only identity shared with the widget and backups, never credentials.
struct KDYZMBinding: Codable, Equatable, Hashable {
    var origin: String
    var accountID: String
    var orderID: String
    var shipmentID: String
}
struct KDYZMLogisticsEvent: Codable, Equatable, Hashable {
    var time: Double
    var timeText: String
    var description: String
    var location: String
}

/// Chinese presentation only; preserve device timezone and stored instants.
enum ShipmentDateDisplay {
    static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

struct Shipment: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var trackingNumber: String
    var carrierName: String
    var carrierCode: String
    var status: ShipmentStatus
    var note: String
    var pickupCode: String
    var createdAt: Date
    var updatedAt: Date
    var lastCheckedAt: Date?
    var reminderDate: Date?
    // Optional fields keep old shipment JSON and backups decodable.
    var logisticsInfo: String?
    var logisticsTime: Date?
    var queryInfo: String?
    var uapiCarrierCode: String?
    var lastQueriedAt: Date?
    // Batch scheduling only; a failed attempt must not change successful query data.
    var lastQueryAttemptAt: Date?
    // Optional source metadata remains compatible with old JSON and the widget target.
    var originPlatform: String?
    // nil follows originPlatform; "uapi" or "tmini" explicitly overrides the source channel.
    var refreshChannel: String?
    var taobaoOrderID: String?
    var logisticsSource: String?
    var lastRefreshError: String?
    // JD/PDD order identity is separate from both the waybill and Taobao binding.
    var platformOrderID: String?
    // Validated platform logistics entry; never contains credentials.
    var platformLogisticsURL: String?
    var backendBinding: KDYZMBinding?
    var backendEvents: [KDYZMLogisticsEvent]?
    var backendLogisticsUpdatedAt: Date?
    var backendRefreshJobID: String?
    var backendRefreshGeneration: UUID?
    var backendPreviousHistory: String?

    /// Store only public logistics parameters, never arbitrary platform tokens.
    static func logisticsEntry(_ raw: String, orderID: String) -> String? {
        guard raw.utf8.count <= 8192, let c = URLComponents(string: raw), c.scheme == "https",
              c.host == "trade.m.jd.com", c.path == "/order/deal_wuliu_jdm.shtml",
              c.user == nil, c.password == nil, c.fragment == nil, c.port == nil || c.port == 443,
              let items = c.queryItems, items.filter({ $0.name == "dealId" }).map(\.value) == [Optional(orderID)] else { return nil }
        let allowed = Set(["from", "dealState", "dealId", "orderType", "skuid", "shopid", "source"])
        let kept = items.filter { allowed.contains($0.name) }
        guard Set(kept.map(\.name)).count == kept.count,
              kept.allSatisfy({ ($0.value ?? "").utf8.count <= 256 }) else { return nil }
        var safe = URLComponents(string: "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml")!
        safe.queryItems = kept
        return safe.url?.absoluteString
    }

    static func validPlatformOrderID(_ orderID: String, platform: String) -> Bool {
        let pattern: String
        switch platform {
        case "jd": pattern = #"\A[0-9]{6,32}\z"#
        case "pdd": pattern = #"\A[0-9]{6}-[0-9]{6,32}\z"#
        default: return false
        }
        return orderID.range(of: pattern, options: .regularExpression) != nil
    }

    init(
        id: UUID = UUID(),
        trackingNumber: String,
        carrierName: String,
        carrierCode: String,
        status: ShipmentStatus = .inTransit,
        note: String = "",
        pickupCode: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastCheckedAt: Date? = nil,
        reminderDate: Date? = nil,
        logisticsInfo: String? = nil,
        logisticsTime: Date? = nil,
        queryInfo: String? = nil,
        uapiCarrierCode: String? = nil,
        lastQueriedAt: Date? = nil,
        lastQueryAttemptAt: Date? = nil,
        originPlatform: String? = nil,
        refreshChannel: String? = nil,
        taobaoOrderID: String? = nil,
        logisticsSource: String? = nil,
        lastRefreshError: String? = nil,
        platformOrderID: String? = nil,
        platformLogisticsURL: String? = nil
    ) {
        self.id = id
        self.trackingNumber = trackingNumber
        self.carrierName = carrierName
        self.carrierCode = carrierCode
        self.status = status
        self.note = note
        self.pickupCode = pickupCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastCheckedAt = lastCheckedAt
        self.reminderDate = reminderDate
        self.logisticsInfo = logisticsInfo
        self.logisticsTime = logisticsTime
        self.queryInfo = queryInfo
        self.uapiCarrierCode = uapiCarrierCode
        self.lastQueriedAt = lastQueriedAt
        self.lastQueryAttemptAt = lastQueryAttemptAt
        self.originPlatform = originPlatform
        self.refreshChannel = refreshChannel
        self.taobaoOrderID = taobaoOrderID
        self.logisticsSource = logisticsSource
        self.lastRefreshError = lastRefreshError
        self.platformOrderID = platformOrderID
        self.platformLogisticsURL = platformLogisticsURL
    }
}

enum ShipmentStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case inTransit = "运输中"
    case outForDelivery = "派送中"
    case readyForPickup = "待取件"
    case delivered = "已签收"
    case exception = "异常"
    case archived = "已归档"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .inTransit: return "truck.box"
        case .outForDelivery: return "figure.walk.motion"
        case .readyForPickup: return "shippingbox"
        case .delivered: return "checkmark.seal.fill"
        case .exception: return "exclamationmark.triangle.fill"
        case .archived: return "archivebox.fill"
        }
    }
}
