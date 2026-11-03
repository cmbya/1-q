#!/usr/bin/env python3
"""Offline source contracts, not execution of Swift or XCTest."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
def source(name):
    return (ROOT / 'ParcelKeeper/Services' / (name + '.swift')).read_text()
class PickupOmissionsContract(unittest.TestCase):
    def test_collection_precedes_coarse_conflicts_but_not_response_guards(self):
        s = source('UAPITrackingClient')
        evidence = s.index('let collected = MallDeliveryState.recipientCollected(')
        self.assertLess(s.index('if dated.dropFirst()'), evidence)
        self.assertLess(evidence, s.index('if is_completed == true, let mapped'))
        self.assertIn('if !collected {', s)
    def test_independent_events_keep_independent_conditional_scope(self):
        s = source('MallDeliveryState')
        self.assertIn('static func recipientCollected(events: [String]) -> Bool', s)
        self.assertIn('events.contains { recipientCollected(latest: $0) }', s)
        self.assertIn('guard !isConditional(latest)', s)
    def test_phone_cleanup_has_no_filesystem_or_lock_dependency(self):
        s = source('PaidTrackingCache')
        body = s.split('func mutatePhone(number:', 1)[1].split('private func validateIdentity', 1)[0]
        self.assertNotIn('locked', body)
        self.assertIn('try keys.delete()', body)
        self.assertIn('guard try keys.read() == nil', body)
        self.assertLess(body.index('try keys.delete()'), body.index('try mutation()'))
    def test_same_value_save_still_retires_historical_secret(self):
        s = source('ShipmentPhoneStore')
        self.assertNotIn('guard try read(for: shipment) != phone else { return }', s)
        self.assertIn('try cache.mutatePhone', s)
if __name__ == '__main__':
    unittest.main()
