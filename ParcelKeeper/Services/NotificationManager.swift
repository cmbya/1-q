import Foundation
import UserNotifications

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
        let content = UNMutableNotificationContent()
        content.title = "快递提醒"
        content.body = "\(shipment.carrierName) · \(shipment.trackingNumber) 记得查看物流或取件。"
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
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

    private func reminderIdentifier(for id: UUID) -> String {
        "shipment-reminder-\(id.uuidString)"
    }
}
