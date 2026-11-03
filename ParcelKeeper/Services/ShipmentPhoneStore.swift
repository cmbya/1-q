import Foundation

/// Device-only, per-record credentials. Never encoded into the shared dataset or backups.
struct ShipmentPhoneStore {
    var keys: any AIKeyStore = AIKeychainStore(service: "ParcelKeeper.UAPI.ShipmentPhone")
    var cache = PaidTrackingCache()

    private func account(_ shipment: Shipment) throws -> String {
        shipment.id.uuidString + ":" + (try ShipmentShortcutParser.number(shipment.trackingNumber))
    }
    static func validate(_ phone: String) throws {
        guard phone.utf8.count == 4, phone.utf8.allSatisfy({ (48...57).contains($0) }) else { throw UAPIError.invalidPhone }
    }
    func read(for shipment: Shipment) throws -> String? {
        let identity = try account(shipment)
        let value: String?
        do { value = try keys.read(endpoint: identity) } catch { throw UAPIError.keychain }
        if let value { try Self.validate(value) }
        return value
    }
    func save(_ phone: String, for shipment: Shipment) throws {
        try Self.validate(phone)
        let identity = try account(shipment)
        // Even identical saves retire a historical Keychain context. No cache I/O.
        // Callers own the tracking lease; keep the authoritative phone if cleanup fails.
        let unchanged = try read(for: shipment) == phone
        do {
            try cache.mutatePhone(number: try ShipmentShortcutParser.number(shipment.trackingNumber)) {
                if !unchanged { try keys.save(phone, endpoint: identity) }
                guard try keys.read(endpoint: identity) == phone else { throw UAPIError.keychain }
            }
        } catch { throw UAPIError.keychain }
    }
    func clear(for shipment: Shipment) throws {
        let identity = try account(shipment)
        do {
            // Also removes the separate cache Keychain suffix, including legacy
            // entries. Delete/import retirement uses this same verified path.
            try cache.mutatePhone(number: try ShipmentShortcutParser.number(shipment.trackingNumber)) {
                try keys.delete(endpoint: identity)
                guard try keys.read(endpoint: identity) == nil else { throw UAPIError.keychain }
            }
        } catch { throw UAPIError.keychain }
    }
}
