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
        for token in ['guard local.status != .archived', 'latest == old', 'Set(newest)', 'local.status != .readyForPickup', 'local.pickupCode.isEmpty', 'data.records[record].code = code', 'local.refreshChannel == nil', 'local.logisticsSource == "kdyzm"', 'timeout: remainingTimeout()', 'case "signed": local.status = .delivered']:
            self.assertIn(token, merge)
        for token in ['preview.scope.validated()', 'static func validToken', 'pcd_', 'config.timeoutIntervalForResource = request.timeoutInterval', 'min(12, timeout)']:
            self.assertIn(token, client)
        self.assertIn('for id in affected.map', store)
        self.assertNotIn('data.shipments.count == before.shipments.count', store)
        self.assertIn('lastRefreshError = KDYZMError.safe(error)', refresh)
    def test_ui(self):
        s = (ROOT/'ParcelKeeper/Views/KDYZMSettingsView.swift').read_text()
        for token in ['SecureField', '预检', '确认授权', '解绑', 'isHistoricalSnapshot', '同步京东']:
            self.assertIn(token, s)
if __name__ == '__main__': unittest.main()
