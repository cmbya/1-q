"""Offline source contracts, NOT Swift execution. Run with python3 -B."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
SYNC = (ROOT / 'ParcelKeeper/Services/KDYZMSync.swift').read_text()
STATE = (ROOT / 'ParcelKeeper/Services/MallDeliveryState.swift').read_text()

class PickupRepairContract(unittest.TestCase):
    def test_routing_is_explicit_not_historical_source(self):
        self.assertIn('if local.refreshChannel == nil {', SYNC)
        self.assertNotIn('local.logisticsSource == nil || local.logisticsSource == "kdyzm"', SYNC)
    def test_snapshot_counts_only_real_changes(self):
        self.assertIn('var unchanged = 0', SYNC)
        self.assertIn('if local != original { result.updated += 1 }', SYNC)
        self.assertIn('else { result.unchanged += 1 }', SYNC)
        self.assertIn('if local != original { local.updatedAt = Date() }', SYNC)
    def test_narrow_collection_helper_and_latest_only(self):
        self.assertIn('static func recipientCollected(latest: String) -> Bool', STATE)
        self.assertIn('if recipientCollected(latest: latest) { return .delivered }', STATE)
        self.assertIn('MallDeliveryState.recipientCollected(events: latestDescriptions)', SYNC)
        self.assertIn('incoming.filter { (try? KDYZMTime.date($0.time)) == latest }.map(\\.description)', SYNC)
        self.assertNotIn('.map(\\.description).sorted().joined(separator: "，")', SYNC)
        self.assertIn('latestDescriptions', SYNC)
    def test_refresh_returns_committed_status_transition(self):
        self.assertIn('let wasDelivered = data.shipments[index].status == .delivered', SYNC)
        self.assertIn('newlyDelivered = !wasDelivered && data.shipments[index].status == .delivered', SYNC)
        self.assertIn('return newlyDelivered', SYNC)
    def test_time_gates_removed_but_cleanup_and_generation_preserved(self):
        for token in ['successTime < old', 'latest.map({ $0 >= old })', '(remote.logisticsCheckedAt ?? 0) >= createdAt', '(remote.logisticsUpdatedAt ?? 0) >= createdAt']:
            self.assertNotIn(token, SYNC)
        for token in ['try await clearJob(expectedID', 'backendRefreshGeneration == credential.generation']:
            self.assertIn(token, SYNC)
        self.assertNotIn('.isCompleted =', SYNC)

if __name__ == '__main__':
    unittest.main()
