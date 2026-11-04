"""Auxiliary source contract only: does not compile or execute Swift."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class KDYZMContract(unittest.TestCase):
    def test_security(self):
        s = (ROOT/'ParcelKeeper/Services/KDYZMClient.swift').read_text()
        for token in ['URLSessionConfiguration.ephemeral', 'httpShouldSetCookies = false', 'completionHandler(nil)', '2_000_000', 'DEVICE_UNAUTHORIZED', 'SecItemUpdate', 'kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly', 'generation', '/v1/pairing-codes/preview']:
            self.assertIn(token, s)
        self.assertNotIn('UserDefaults', s)
    def test_merge_and_jobs(self):
        s = (ROOT/'ParcelKeeper/Services/KDYZMSync.swift').read_text()
        for token in ['schemaVersion == 1', 'legacyAccountIds', 'familyIds', 'logisticsState == "ok"', 'logisticsTruncated', 'sameIdentity', 'store.transaction', 'Task.checkCancellation', '/v1/sync-jobs/', '/refresh', 'retryAt', 'lastQueriedAt', 'generation']:
            self.assertIn(token, s)
        r = (ROOT/'ParcelKeeper/Services/TrackingRefreshService.swift').read_text()
        self.assertIn('KDYZMRefreshService', r)
        self.assertIn('backendBinding', r)
    def test_review_safety_guards(self):
        merge = (ROOT/'ParcelKeeper/Services/KDYZMSync.swift').read_text()
        client = (ROOT/'ParcelKeeper/Services/KDYZMClient.swift').read_text()
        store = (ROOT/'ParcelKeeper/Services/ShipmentStore.swift').read_text()
        refresh = (ROOT/'ParcelKeeper/Services/TrackingRefreshService.swift').read_text()
        for token in ['guard local.status != .archived', 'local.logisticsInfo = incoming.sorted', 'local.status != .delivered', 'case "transit": local.status = .inTransit', 'local.pickupCode.isEmpty', 'data.records[record].code = code', 'local.refreshChannel == nil', 'local.logisticsSource = "kdyzm"', 'timeout: remainingTimeout()', 'case "signed": local.status = .delivered']:
            self.assertIn(token, merge)
        for token in ['preview.scope.validated()', 'static func validToken', 'pcd_', 'config.timeoutIntervalForResource = request.timeoutInterval', 'min(12, timeout)']:
            self.assertIn(token, client)
        self.assertIn('for id in affected.map', store)
        self.assertNotIn('data.shipments.count == before.shipments.count', store)
        self.assertIn('lastRefreshError = KDYZMError.safe(error)', refresh)
    def test_ui(self):
        s = (ROOT/'ParcelKeeper/Views/KDYZMSettingsView.swift').read_text()
        for token in ['SecureField', '预检', '确认授权', '解绑', 'isHistoricalSnapshot', '同步']:
            self.assertIn(token, s)
    def test_all_platform_source_contract(self):
        merge = (ROOT/'ParcelKeeper/Services/KDYZMSync.swift').read_text()
        store = (ROOT/'ParcelKeeper/Services/ShipmentStore.swift').read_text()
        refresh = (ROOT/'ParcelKeeper/Services/TrackingRefreshService.swift').read_text()
        # Backend sync stays platform-agnostic; independent JD import is now explicitly authorized.
        self.assertNotIn('platform == "jd"', merge)
        self.assertIn('platform == "pdd" || platform == "jd"', store)
        self.assertIn('originPlatform: order.platform', merge)
        self.assertIn('local.originPlatform = order.platform', merge)
        self.assertIn('case backend', refresh)
        self.assertIn('backendCount', refresh)
        route = refresh.split('private static func route(')[1].split('func setRefreshChannel')[0]
        self.assertIn('throw RetiredTrackingChannel.backend', route)
        self.assertNotIn('return .backend', route)
        self.assertNotIn('KDYZMSettingsView()', (ROOT/'ParcelKeeper/Views/SettingsView.swift').read_text())
        self.assertIn('if route == .backend { report.backendCount += 1 }', refresh)
        self.assertIn('$0.platform == before.originPlatform && $0.platformOrderId == before.platformOrderID', merge)
        self.assertIn('remoteNumbers[number]?.count == 1', merge)
        self.assertIn('local.taobaoOrderID == nil', merge)
        self.assertNotIn('后台（京东）', (ROOT/'ParcelKeeper/Intents/TrackingRefreshIntents.swift').read_text())
if __name__ == '__main__': unittest.main()

