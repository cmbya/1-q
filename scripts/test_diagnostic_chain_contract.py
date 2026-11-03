"""Source contracts only: Linux cannot execute the iOS XCTest suite."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
def source(name): return (ROOT / 'ParcelKeeper/Services' / name).read_text()
class DiagnosticChainContract(unittest.TestCase):
    def test_schema_and_allowlist(self):
        s = source('DiagnosticLog.swift')
        for token in ['enum DiagnosticStage', 'let stage: DiagnosticStage?', 'case quota, rateLimited, parse, accounting, configuration', 'olderQuery', 'operationOrder.count >= Self.maximumEntries']:
            self.assertIn(token, s)
        self.assertIn('decoded.schema == 1', s)
    def test_sync_pair_covers_preconditions(self):
        s = source('ShipmentStore.swift').split('func syncKDYZM(')[1].split('func shipment(')[0]
        self.assertLess(s.index('.syncStarted'), s.index('guard let storage'))
        for token in ['.syncFinished', '.syncFailed', '.localRead', '.snapshot', '.association', '.localWrite', '.presentation']:
            self.assertIn(token, s)
    def test_backend_same_operation_and_original_failure(self):
        s = source('KDYZMSync.swift')
        for token in ['operation: UUID = UUID()', '.jobCreate', '.jobResume', '.jobPoll', '.snapshot', '.merge', '.save', '.cleanup', 'originalReason', 'originalStage', 'cleanupReason']:
            self.assertIn(token, s)
        self.assertNotIn('throw KDYZMTerminalResultError()', s)
    def test_refresh_preconditions_and_distinct_time(self):
        s = source('TrackingRefreshService.swift')
        for token in ['.olderQuery', '.accounting', '.quota', '.rateLimited', '.configuration', 'operation: logID', 'func performRefresh(']:
            self.assertIn(token, s)
        s = s.split('func refresh(id:')[1].split('func performRefresh(')[0]
        self.assertLess(s.index('.trackingStarted'), s.index('performRefresh('))
if __name__ == '__main__': unittest.main()
