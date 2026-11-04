#!/usr/bin/env python3
"""Offline source contracts; these do not compile Swift or exercise system notifications."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
def read(path):
    return (ROOT / path).read_text()

class UIRepairContracts(unittest.TestCase):
    def test_default_channel_is_visible_and_backend_remains_available(self):
        detail = read('ParcelKeeper/Views/ShipmentDetailView.swift')
        self.assertIn('Picker("默认渠道"', detail)
        self.assertIn('case "kdyzm": return "取件助手后台"', detail)

    def test_reminder_sync_is_read_only_and_observes_commits_and_unlock(self):
        detail = read('ParcelKeeper/Views/ShipmentDetailView.swift')
        self.assertNotIn('.onChange(of: reminderEnabled)', detail)
        self.assertNotIn('.onChange(of: reminderDate)', detail)
        self.assertIn('Binding(', detail)
        self.assertIn('.onChange(of: shipment?.reminderDate)', detail)
        self.assertIn('.onChange(of: store.reminderOperationInProgress)', detail)
        sync = detail.split('private func synchronizeReminderControls()', 1)[1].split('\n    private func ', 1)[0]
        self.assertIn('reminderBusy || store.reminderOperationInProgress', sync)
        self.assertIn('shipment?.reminderDate', sync)
        for forbidden in ['scheduleReminder(', 'cancelReminder(', 'updateReminderThrowing', 'requestAuthorization(']:
            self.assertNotIn(forbidden, sync)
        self.assertIn('store.isHistoricalSnapshot', detail)
        self.assertIn('store.endReminderOperation(); synchronizeReminderControls()', detail)

    def test_settings_refreshes_permission_on_active_without_requesting(self):
        settings = read('ParcelKeeper/Views/SettingsView.swift')
        self.assertIn('@Environment(\\.scenePhase)', settings)
        active = settings.split('.onChange(of: scenePhase)', 1)[1].split('.fileImporter', 1)[0]
        self.assertIn('phase == .active', active)
        self.assertIn('await refreshNotificationStatus()', active)
        self.assertNotIn('requestAuthorization', active)

    def test_foreground_delegate_is_retained_and_registration_is_permission_free(self):
        manager = read('ParcelKeeper/Services/NotificationManager.swift')
        self.assertIn('NSObject, UNUserNotificationCenterDelegate', manager)
        self.assertIn('completionHandler(Self.foregroundPresentationOptions)', manager)
        self.assertIn('UNNotificationPresentationOptions { [.banner, .list, .sound] }', manager)
        register = manager.split('func registerForForegroundPresentation()', 1)[1].split('\n    func ', 1)[0]
        self.assertIn('center.delegate = self', register)
        self.assertNotIn('requestAuthorization', register)
        app = read('ParcelKeeper/App/ParcelKeeperApp.swift')
        self.assertIn('NotificationManager.shared.registerForForegroundPresentation()', app)
        self.assertIn('await store.reconcileReminders()', app)

    def test_pickup_deep_link_validation_and_group_selection(self):
        content = read('ParcelKeeper/Views/ContentView.swift')
        self.assertIn('enum PickupDeepLink', content)
        for token in ['components.user == nil', 'components.password == nil', 'components.port == nil', 'components.query == nil', 'components.fragment == nil', 'percentEncodedPath', 'UUID(uuidString:', 'caseInsensitiveCompare']:
            self.assertIn(token, content)
        self.assertIn('PickupView(selectedGroupID: $selectedPickupGroupID)', content)
        self.assertIn('store.groups.contains', content)
        self.assertIn('url.host == "shipments"', content)
        self.assertIn('url.host == "train"', content)
        pickup = read('ParcelKeeper/Views/PickupView.swift')
        self.assertIn('@Binding var selectedGroupID: UUID?', pickup)
        self.assertIn('ForEach(visibleGroups)', pickup)
        self.assertIn('selectedGroupID = nil', pickup)
        self.assertIn('expected: record', pickup)

    def test_widget_open_is_group_aware_and_completion_remains_separate(self):
        widget = read('ParcelKeeperWidget/ParcelKeeperWidget.swift')
        self.assertIn('Link(destination: OpenPickupAppIntent.destination(groupID: entry.groupID))', widget)
        self.assertNotIn('OpenURLIntent(', widget)
        self.assertIn('some IntentResult', widget)
        self.assertIn('parcelkeeper://pickup', widget)
        self.assertIn('caseInsensitiveCompare', widget)
        self.assertIn('.widgetURL(', widget)
        self.assertIn('CompletePickupIntent(groupID: group, record: record)', widget)
        self.assertIn('expectedCode: expectedCode, expectedUpdatedAt: expectedUpdatedAt', widget)
        slots = read('ParcelKeeperWidget/SlotWidgets.swift')
        for slot in 'abcdefghij':
            self.assertIn(f'SlotWidget(slot: .{slot})', slots)
        self.assertIn('PickupWidgetView(entry:', slots)

    def test_pickup_widget_uses_dynamic_type_not_fixed_small_fonts(self):
        widget = read('ParcelKeeperWidget/ParcelKeeperWidget.swift').split('struct PickupWidgetView', 1)[1]
        self.assertNotRegex(widget, r'font\(\.system\(size:')
        self.assertNotIn('minimumScaleFactor', widget)
        self.assertIn('@Environment(\\.dynamicTypeSize)', widget)
        self.assertIn('isAccessibilitySize', widget)
        self.assertIn('.font(.caption)', widget)

if __name__ == '__main__':
    unittest.main(verbosity=2)

