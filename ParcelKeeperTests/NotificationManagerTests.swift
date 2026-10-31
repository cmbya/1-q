import XCTest
@testable import ParcelKeeper

final class NotificationManagerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)

    private enum SchedulingFailure: LocalizedError {
        case rejected
        var errorDescription: String? { "模拟调度失败" }
    }

    // Models UNUserNotificationCenter.add: a failed replacement leaves the old
    // request untouched. No test contacts the real notification center.
    private final class Center {
        var pending: [String: Shipment] = [:]
        var unrelated = Set(["another-feature-request"])
        var authorized = true
        var authorizationCalls = 0
        var attempts: [UUID] = []
        var failures = Set<UUID>()
        var removed: [String] = []
        var beforeSchedule: ((Shipment) -> Void)?

        func reconcile(_ shipments: [Shipment], now: Date) async -> [String] {
            await ReminderReconciliation.reconcile(
                shipments: shipments,
                now: now,
                pendingIdentifiers: { Array(self.pending.keys) + Array(self.unrelated) },
                requestAuthorization: {
                    self.authorizationCalls += 1
                    return self.authorized
                },
                schedule: { shipment, date in
                    self.attempts.append(shipment.id)
                    self.beforeSchedule?(shipment)
                    if self.failures.contains(shipment.id) { throw SchedulingFailure.rejected }
                    var scheduled = shipment
                    scheduled.reminderDate = date
                    self.pending[ReminderReconciliation.identifier(for: shipment.id)] = scheduled
                },
                remove: { identifiers in
                    self.removed.append(contentsOf: identifiers)
                    for id in identifiers {
                        self.pending.removeValue(forKey: id)
                        self.unrelated.remove(id)
                    }
                }
            )
        }

        func seed(_ shipment: Shipment) {
            pending[ReminderReconciliation.identifier(for: shipment.id)] = shipment
        }
    }

    private func shipment(date: Date?, number: String = "TEST-001") -> Shipment {
        Shipment(trackingNumber: number, carrierName: "测试快递", carrierCode: "test", reminderDate: date)
    }

    func testFailedSameIDReplacementRemovesOldDateAndContent() async {
        let center = Center()
        let old = shipment(date: now.addingTimeInterval(60))
        var imported = old
        imported.reminderDate = now.addingTimeInterval(120)
        imported.trackingNumber = "IMPORTED-B"
        center.seed(old)
        center.failures.insert(old.id)
        center.beforeSchedule = { value in
            XCTAssertNil(center.pending[ReminderReconciliation.identifier(for: value.id)])
        }

        let errors = await center.reconcile([imported], now: now)

        XCTAssertTrue(center.pending.isEmpty, "Imported B failed: old A must not remain active")
        XCTAssertEqual(center.attempts, [old.id])
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("IMPORTED-B"))
        XCTAssertTrue(errors[0].contains("未启用"))
        XCTAssertEqual(center.unrelated, Set(["another-feature-request"]))
    }

    func testPermissionDeniedClearsDesiredAndObsoleteOwnedRequests() async {
        let center = Center()
        let old = shipment(date: now.addingTimeInterval(60))
        var imported = old
        imported.reminderDate = now.addingTimeInterval(120)
        center.seed(old)
        center.seed(shipment(date: now.addingTimeInterval(90), number: "OBSOLETE"))
        center.authorized = false

        let errors = await center.reconcile([imported], now: now)

        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertTrue(center.attempts.isEmpty)
        XCTAssertEqual(center.authorizationCalls, 1)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("没有通知权限"))
        XCTAssertTrue(errors[0].contains("已清除"))
        XCTAssertEqual(center.unrelated, Set(["another-feature-request"]))
    }

    func testSuccessReplacesSameIDWithImportedDateAndContent() async {
        let center = Center()
        let old = shipment(date: now.addingTimeInterval(60))
        var imported = old
        imported.reminderDate = now.addingTimeInterval(120)
        imported.trackingNumber = "NEW-NUMBER"
        imported.carrierName = "新快递"
        center.seed(old)

        let errors = await center.reconcile([imported], now: now)

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(center.pending, [ReminderReconciliation.identifier(for: imported.id): imported])
        XCTAssertEqual(center.unrelated, Set(["another-feature-request"]))
    }

    func testPastEqualAndMissingDatesAreRemovedWithoutAuthorizationOrScheduling() async {
        let center = Center()
        let past = shipment(date: now.addingTimeInterval(-1), number: "PAST")
        let equal = shipment(date: now, number: "EQUAL")
        let missing = shipment(date: nil, number: "NONE")
        for value in [past, equal, missing] { center.seed(value) }

        let errors = await center.reconcile([past, equal, missing], now: now)

        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertTrue(center.attempts.isEmpty)
        XCTAssertEqual(center.authorizationCalls, 0)
        XCTAssertEqual(center.unrelated, Set(["another-feature-request"]))
    }

    func testEmptyImportRemovesOnlyShipmentReminderNamespace() async {
        let center = Center()
        center.seed(shipment(date: now.addingTimeInterval(60)))
        center.unrelated.formUnion(["shipment-reminder", "other-shipment-reminder-123"])
        let expectedUnrelated = center.unrelated

        let errors = await center.reconcile([], now: now)

        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(center.unrelated, expectedUnrelated)
        XCTAssertEqual(center.authorizationCalls, 0)
        XCTAssertTrue(center.removed.allSatisfy { $0.hasPrefix("shipment-reminder-") })
    }

    func testPartialFailureContinuesAndKeepsOnlySuccessfulImportedRequests() async {
        let center = Center()
        let failedFirst = shipment(date: now.addingTimeInterval(60), number: "FAIL-1")
        let succeeded = shipment(date: now.addingTimeInterval(90), number: "SUCCESS")
        let failedLast = shipment(date: now.addingTimeInterval(120), number: "FAIL-2")
        for value in [failedFirst, succeeded, failedLast] { center.seed(value) }
        center.seed(shipment(date: now.addingTimeInterval(180), number: "OBSOLETE"))
        center.failures = [failedFirst.id, failedLast.id]

        let errors = await center.reconcile([failedFirst, succeeded, failedLast], now: now)

        XCTAssertEqual(center.attempts, [failedFirst.id, succeeded.id, failedLast.id])
        XCTAssertEqual(center.pending, [ReminderReconciliation.identifier(for: succeeded.id): succeeded])
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors[0].contains("FAIL-1"))
        XCTAssertTrue(errors[1].contains("FAIL-2"))
        XCTAssertEqual(center.unrelated, Set(["another-feature-request"]))
    }

    func testFailureCleansUpRequestEvenIfSchedulingMutatedBeforeThrowing() async {
        let center = Center()
        let imported = shipment(date: now.addingTimeInterval(60))
        center.failures.insert(imported.id)
        center.beforeSchedule = { value in center.seed(value) }

        let errors = await center.reconcile([imported], now: now)

        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(center.unrelated, Set(["another-feature-request"]))
    }
}
