"""Source contracts only; Swift runtime coverage lives in XCTest and requires Apple CI."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class NetworkRefreshNoTimeGatesContract(unittest.TestCase):
    def test_network_result_does_not_compare_saved_timestamps(self):
        source = (ROOT / 'ParcelKeeper/Services/TrackingRefreshService.swift').read_text()
        merge = source.split('let delivered = try store.transaction')[1].split('reloadWidgets()')[0]
        for gate in ['incoming >= old', 'result.queriedAt < queried', 'throw ShipmentShortcutError.olderUpdate']:
            self.assertNotIn(gate, merge)
        for assignment in ['current.logisticsInfo = result.logisticsInfo', 'current.logisticsTime = result.logisticsTime', 'current.queryInfo = result.queryInfo', 'current.lastQueriedAt = result.queriedAt', 'current.status = state']:
            self.assertIn(assignment, merge)
        for guard in ['Self.sameIdentity(current, before)', 'current.status != .archived', 'current.status == .delivered', 'data.records[linked].id == linkedID', 'validateConfiguration']:
            self.assertIn(guard, merge)

    def test_backend_merge_accepts_older_and_equal_conflicting_results(self):
        source = (ROOT / 'ParcelKeeper/Services/KDYZMSync.swift').read_text()
        merge = source.split('static func update(')[1].split('@discardableResult')[0]
        for gate in ['successTime < old', '$0 >= old', 'latest == old', 'sameLatest', 'func reject(']:
            self.assertNotIn(gate, merge)
        for token in ['guard local.status != .archived', 'remote.logisticsState == "ok"', '!incoming.isEmpty', 'local.backendLogisticsUpdatedAt = successTime', 'local.logisticsInfo = incoming.sorted', 'local.logisticsTime = latest', 'local.status != .delivered']:
            self.assertIn(token, merge)
        self.assertIn('case "transit": local.status = .inTransit', merge)

    def test_completed_job_does_not_require_snapshot_newer_than_job(self):
        source = (ROOT / 'ParcelKeeper/Services/KDYZMSync.swift').read_text()
        merge = source.split('let snapshot = try await client.snapshot')[1].split('reloadWidgets()')[0]
        for gate in ['job.createdAt', 'remote.logisticsCheckedAt', 'remote.logisticsUpdatedAt']:
            self.assertNotIn(gate, merge)
        for token in ['remote.logisticsState == "ok"', '!(remote.logisticsEvents ?? []).isEmpty', 'sameIdentity', 'backendRefreshGeneration == credential.generation', 'connection.commit(credential)', 'acquireTrackingQuery', 'snapshot.hiddenIds', 'CarrierDetector.sanitize(remote.waybillNo)']:
            self.assertIn(token, merge)

    def test_shortcut_text_and_network_both_accept_older_input(self):
        source = (ROOT / 'ParcelKeeper/Services/ShipmentShortcutService.swift').read_text()
        upsert = source.split('@discardableResult func upsert(', 1)[1]
        self.assertNotIn('new < old', upsert)
        self.assertNotIn('shipment.logisticsTime != nil && value.logisticsTime == nil', upsert)
        intents = (ROOT / 'ParcelKeeper/Intents/TrackingRefreshIntents.swift').read_text()
        self.assertIn('TrackingRefreshService', intents)

if __name__ == '__main__':
    unittest.main()
