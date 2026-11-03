#!/usr/bin/env python3
"""Offline source assertions, NOT Swift compilation/XCTest/runtime verification."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
def text(path):
    return (ROOT / path).read_text()
class PaidCacheContract(unittest.TestCase):
    def test_client_cache_precedes_paid_dispatch(self):
        for name in ['Tmini', 'UAPI']:
            source = text(f'ParcelKeeper/Services/{name}TrackingClient.swift')
            query = source.split('    func query(trackingNumber:', 1)[1]
            self.assertLess(query.index('cache.lookup(identity)'), query.index('network.data(for: request)'))
            self.assertIn('let cachedResult = try cache.lookup(identity)', source)
            self.assertIn('if !ignoreCache, let cached = cachedResult', source)
            self.assertIn('ignoreCache: Bool = false', source)
            self.assertIn('self.ignoreCache = ignoreCache', source)
            self.assertIn('cache.store(', query)
            self.assertIn('catch let error as PaidTrackingCacheError { throw error }', query)
            if name == 'Tmini':
                self.assertLess(query.index('cache.lookup(identity)'), query.index('usage.recordDispatch()'))
            else:
                self.assertLess(query.index('cache.lookup(identity)'), query.index('settings.recordUsage('))
    def test_boundaries_storage_and_phone_identity(self):
        source = text('ParcelKeeper/Services/PaidTrackingCache.swift')
        for token in ['age >= 0 && age < ttl', 'case .delivered: ttl = 604800', 'case .outForDelivery: ttl = 1800', 'case .readyForPickup: ttl = 21600', 'default: ttl = 7200', 'result.isCached = true', 'isExcludedFromBackup = true',
                      'LOCK_EX | LOCK_NB', '.atomic', 'entries.prefix(256)', '8_000_000', 'validateIdentity(identity)',
                      '$0.startedAt > startedAt', '$0.result.queriedAt > result.queriedAt', 'UUID().uuidString']:
            self.assertIn(token, source)
        identity = source.split('struct Identity:', 1)[1].split('private struct Entry', 1)[0]
        self.assertNotIn('let phone:', identity)
        self.assertNotIn('let key:', identity)
        self.assertNotIn('SHA256.hash(data: Data(phone', source)
    def test_feedback_and_batch_cache_not_charged(self):
        service = text('ParcelKeeper/Services/TrackingRefreshService.swift')
        for token in ['cacheFeedback(result.isCached)', 'report.cachedCount += 1', 'report.uapiCount -= 1', 'report.tminiCount -= 1']:
            self.assertIn(token, service)
        self.assertIn('ignoreCache: ignoreCache', service)
        view = text('ParcelKeeper/Views/ShipmentDetailView.swift')
        self.assertIn('.confirmationDialog("忽略缓存并发起付费查询？"', view)
        self.assertIn('refreshLogistics(mode: mode, ignoreCache: true)', view)
        for path in ['ParcelKeeper/Views/ShipmentDetailView.swift', 'ParcelKeeper/Intents/ShipmentChoiceIntent.swift', 'ParcelKeeper/Intents/TrackingRefreshIntents.swift']:
            source = text(path)
            self.assertIn('cacheFeedback: { isCached = $0 }', source)
            self.assertIn('isCached: isCached', source)
    def test_xctest_coverage_declared(self):
        source = text('ParcelKeeperTests/PaidTrackingCacheTests.swift')
        self.assertEqual(source.count('    func test'), 7)
        self.assertIn('XCTAssertEqual(try usage.summary().points, 4)', source)
        self.assertIn('XCTAssertEqual(settings.usageSnapshot(), billing)', source)
if __name__ == '__main__':
    unittest.main()
