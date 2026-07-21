import Foundation

@MainActor
final class ShipmentStore: ObservableObject {
    @Published private(set) var shipments: [Shipment] = []
    @Published var lastErrorMessage: String?

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let storageURL: URL

    init(fileManager: FileManager = .default) {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let appDirectory = supportDirectory.appendingPathComponent("ParcelKeeper", isDirectory: true)
        try? fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        storageURL = appDirectory.appendingPathComponent("shipments.json")

        load()
    }

    var activeShipments: [Shipment] {
        shipments.filter { $0.status != .archived }
    }

    func shipment(id: UUID) -> Shipment? {
        shipments.first(where: { $0.id == id })
    }

    func contains(trackingNumber: String) -> Bool {
        let normalized = CarrierDetector.sanitize(trackingNumber)
        return shipments.contains { CarrierDetector.sanitize($0.trackingNumber) == normalized }
    }

    @discardableResult
    func add(_ shipment: Shipment) -> Bool {
        guard !contains(trackingNumber: shipment.trackingNumber) else { return false }
        shipments.insert(shipment, at: 0)
        sortShipments()
        save()
        return true
    }

    func delete(id: UUID) {
        shipments.removeAll { $0.id == id }
        save()
    }

    func delete(at offsets: IndexSet, in filteredShipments: [Shipment]) {
        let ids = offsets.map { filteredShipments[$0].id }
        shipments.removeAll { ids.contains($0.id) }
        save()
    }

    func updateStatus(id: UUID, status: ShipmentStatus) {
        update(id: id) { shipment in
            shipment.status = status
            shipment.updatedAt = Date()
        }
    }

    func updateNote(id: UUID, note: String) {
        update(id: id) { shipment in
            shipment.note = note
            shipment.updatedAt = Date()
        }
    }

    func updatePickupCode(id: UUID, pickupCode: String) {
        update(id: id) { shipment in
            shipment.pickupCode = pickupCode
            shipment.updatedAt = Date()
        }
    }

    func updateCarrier(id: UUID, carrier: CarrierOption) {
        update(id: id) { shipment in
            shipment.carrierName = carrier.name
            shipment.carrierCode = carrier.code
            shipment.updatedAt = Date()
        }
    }

    func markChecked(id: UUID) {
        update(id: id) { shipment in
            shipment.lastCheckedAt = Date()
            shipment.updatedAt = Date()
        }
    }

    func updateReminder(id: UUID, date: Date?) {
        update(id: id) { shipment in
            shipment.reminderDate = date
            shipment.updatedAt = Date()
        }
    }

    func makeBackupFile() -> URL? {
        do {
            let data = try encoder.encode(shipments)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let filename = "快递管家备份-\(formatter.string(from: Date())).json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            lastErrorMessage = "生成备份失败：\(error.localizedDescription)"
            return nil
        }
    }

    func importBackup(from url: URL) -> Bool {
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            let imported = try decoder.decode([Shipment].self, from: data)

            var merged = Dictionary(uniqueKeysWithValues: shipments.map { (CarrierDetector.sanitize($0.trackingNumber), $0) })
            for shipment in imported {
                merged[CarrierDetector.sanitize(shipment.trackingNumber)] = shipment
            }

            shipments = Array(merged.values)
            sortShipments()
            save()
            return true
        } catch {
            lastErrorMessage = "导入失败：\(error.localizedDescription)"
            return false
        }
    }

    private func update(id: UUID, mutation: (inout Shipment) -> Void) {
        guard let index = shipments.firstIndex(where: { $0.id == id }) else { return }
        mutation(&shipments[index])
        sortShipments()
        save()
    }

    private func sortShipments() {
        shipments.sort { lhs, rhs in
            if lhs.status == .archived && rhs.status != .archived { return false }
            if lhs.status != .archived && rhs.status == .archived { return true }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            shipments = try decoder.decode([Shipment].self, from: data)
            sortShipments()
        } catch {
            lastErrorMessage = "读取本地数据失败：\(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            let data = try encoder.encode(shipments)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            lastErrorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}
