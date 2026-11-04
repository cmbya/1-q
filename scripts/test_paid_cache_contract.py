#!/usr/bin/env python3
"""Offline source contracts only; NOT Swift/XCTest/runtime verification."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
def text(path):
    return (ROOT / path).read_text()
class PaidCacheContract(unittest.TestCase):
    def test_clients_always_dispatch_without_cache_io(self):
        for name in ['Tmini', 'UAPI']:
            source = text(f'ParcelKeeper/Services/{name}TrackingClient.swift')
            for forbidden in ['cache.lookup(', 'cache.store(', 'cache.identity(', 'self.cache =', 'self.ignoreCache =']:
                self.assertNotIn(forbidden, source)
            self.assertEqual(source.count('await network.data(for: request)'), 1)
            self.assertIn('.reloadIgnoringLocalCacheData', source)
    def test_charging_and_configuration_guards_survive(self):
        tmini = text('ParcelKeeper/Services/TminiTrackingClient.swift')
        self.assertLess(tmini.index('try usage.recordDispatch()'), tmini.index('await network.data(for: request)'))
        self.assertIn('try validateConfiguration(token)', tmini)
        uapi = text('ParcelKeeper/Services/UAPITrackingClient.swift')
        self.assertIn('settings.recordUsage(http, generation: credential.generation', uapi)
        self.assertIn('try settings.validateCredential(credential)', uapi)
        self.assertIn('URLQueryItem(name: "phone", value: phone)', uapi)
    def test_ui_no_cache_controls_and_explicit_network_charge(self):
        view = text('ParcelKeeper/Views/ShipmentDetailView.swift')
        for token in ['forceQueryMode', 'ignoreCache', '忽略缓存', '缓存时长', '普通刷新优先使用缓存']:
            self.assertNotIn(token, view)
        self.assertIn('4积分/次', view)
        self.assertIn('40积分/次', view)
    def test_actual_channel_and_latest_collection_use_shared_resolvers(self):
        view = text('ParcelKeeper/Views/ShipmentDetailView.swift')
        self.assertIn('Picker("默认渠道", selection: Binding(', view)
        self.assertIn('TrackingRefreshService.resolvedChannel(shipment)', view)
        self.assertIn('TrackingRefreshService.resolvedChannel(current, mode: mode)', view)
        self.assertIn('catch { return "不可用" }', view)
        uapi = text('ParcelKeeper/Services/UAPITrackingClient.swift')
        self.assertIn('MallDeliveryState.recipientCollected(latest: latest.track.context)', uapi)
        self.assertIn('collected ? .delivered', uapi)
        for file, token in [
            ('PaidTrackingCacheTests', 'testTminiRepeatedQueriesDispatchAndAddFourPointsEachAndDisabledNeverSends'),
            ('PaidTrackingCacheTests', 'testUAPIRepeatedQueriesDispatchUpdateBillingAndNeverReturnStaleSuccess'),
            ('AuditHighRegressionTests', 'testQueriesIgnoreCorruptAndOversizedLegacyCacheWithoutChangingIt'),
            ('UAPITrackingClientTests', 'testLatestRecipientCollectionCorrectsStaleTransportButNotAgentOrInstructions')
        ]:
            self.assertIn(token, text(f'ParcelKeeperTests/{file}.swift'))
    def test_legacy_phone_lifecycle_remains_available(self):
        source = text('ParcelKeeper/Services/PaidTrackingCache.swift')
        self.assertIn('func mutatePhone(', source)
        self.assertIn('guard try keys.read() == nil', source)
        self.assertIn('历史兼容', source)
if __name__ == '__main__':
    unittest.main()

