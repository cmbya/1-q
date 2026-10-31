import Foundation
import UserNotifications

/// Compensate a scheduled replacement when its persistence fails.
/// A failed restoration must not leave the unsaved replacement active.
enum ReminderCompensation {
    static func restore(oldDate: Date?, now: Date = Date(),
                        schedule: (Date) async throws -> Void,
                        cancel: () -> Void) async throws {
        guard let oldDate, oldDate > now else { cancel(); return }
        do { try await schedule(oldDate) }
        catch { cancel(); throw error }
    }
}

final class NotificationManager {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    private init() {}

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func scheduleReminder(for shipment: Shipment, at date: Date) async throws {
        guard date > Date() else { throw ReminderError.pastDate }
        let content = UNMutableNotificationContent()
        content.title = "快递提醒"
        content.body = "\(shipment.carrierName) · \(shipment.trackingNumber) 记得查看物流或取件。"
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: reminderIdentifier(for: shipment.id),
            content: content,
            trigger: trigger
        )
        try await center.add(request)
    }

    func cancelReminder(for shipmentID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [reminderIdentifier(for: shipmentID)])
    }

    // Reconcile only our own requests after a successful backup import.
    func reconcileReminders(with shipments: [Shipment]) async -> [String] {
        let future = shipments.filter { ($0.reminderDate ?? .distantPast) > Date() }
        let desired = Set(future.map { reminderIdentifier(for: $0.id) })
        let pending = await center.pendingNotificationRequests()
        let obsolete = pending.map(\.identifier).filter {
            $0.hasPrefix("shipment-reminder-") && !desired.contains($0)
        }
        center.removePendingNotificationRequests(withIdentifiers: obsolete)
        guard !future.isEmpty else { return [] }
        guard await requestAuthorization() else { return ["没有通知权限，无法恢复未来提醒。"] }
        var errors: [String] = []
        for shipment in future {
            guard let date = shipment.reminderDate else { continue }
            do { try await scheduleReminder(for: shipment, at: date) }
            catch { errors.append("\(shipment.trackingNumber)：\(error.localizedDescription)") }
        }
        return errors
    }

    enum ReminderError: LocalizedError {
        case pastDate
        var errorDescription: String? { "提醒时间必须晚于当前时间。" }
    }

    private func reminderIdentifier(for id: UUID) -> String {
        "shipment-reminder-\(id.uuidString)"
    }
}
