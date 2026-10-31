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

/// Backup data is already committed when this runs: never restore a pre-import
/// request after scheduling fails. Closure injection keeps tests off the real center.
/// On return, owned requests contain only successfully scheduled future imports;
/// requests outside the shipment-reminder namespace are never removed.
enum ReminderReconciliation {
    private static let prefix = "shipment-reminder-"

    static func identifier(for id: UUID) -> String { "\(prefix)\(id.uuidString)" }

    static func reconcile(
        shipments: [Shipment],
        now: Date,
        pendingIdentifiers: () async -> [String],
        requestAuthorization: () async -> Bool,
        schedule: (Shipment, Date) async throws -> Void,
        remove: ([String]) -> Void
    ) async -> [String] {
        // Clear same-ID requests too: add() may fail without replacing their old
        // dates/content. Also clears obsolete, expired and disabled reminders.
        let owned = await pendingIdentifiers().filter { $0.hasPrefix(prefix) }
        if !owned.isEmpty { remove(owned) }
        let future = shipments.filter { ($0.reminderDate ?? .distantPast) > now }
        guard !future.isEmpty else { return [] }
        guard await requestAuthorization() else {
            return ["没有通知权限，无法恢复未来提醒；旧快递通知已清除，导入的未来提醒均未启用。"]
        }
        var errors: [String] = []
        for shipment in future {
            guard let date = shipment.reminderDate else { continue }
            do { try await schedule(shipment, date) }
            catch {
                // Defensive cleanup if scheduling partially succeeded before throwing.
                remove([identifier(for: shipment.id)])
                errors.append("\(shipment.trackingNumber)：\(error.localizedDescription)（此提醒未启用，旧通知已清除）")
            }
        }
        return errors
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
        await ReminderReconciliation.reconcile(
            shipments: shipments,
            now: Date(),
            pendingIdentifiers: { await self.center.pendingNotificationRequests().map(\.identifier) },
            requestAuthorization: { await self.requestAuthorization() },
            schedule: { shipment, date in try await self.scheduleReminder(for: shipment, at: date) },
            remove: { self.center.removePendingNotificationRequests(withIdentifiers: $0) }
        )
    }

    enum ReminderError: LocalizedError {
        case pastDate
        var errorDescription: String? { "提醒时间必须晚于当前时间。" }
    }

    private func reminderIdentifier(for id: UUID) -> String {
        ReminderReconciliation.identifier(for: id)
    }
}
