"""Source guards, not a substitute for the iOS service XCTest suite."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
def src(name): return (ROOT / 'ParcelKeeper/Services' / name).read_text()
class DiagnosticBlockersContract(unittest.TestCase):
    def test_sync_has_one_shared_stage_owner(self):
        s = src('ShipmentStore.swift').split('func syncKDYZM(')[1].split('func shipment(')[0]
        self.assertIn('trace.begin(.association)', s)
        self.assertNotIn('var stage:', s)
        self.assertIn('trace.failureStage', s)
    def test_cleanup_keeps_original_and_wait_stage(self):
        s = src('KDYZMSync.swift')
        self.assertIn('func cleanupFailure(', s)
        self.assertIn('trace.begin(.jobWait)', s)
        self.assertIn('cleanupReason == nil', s)
        self.assertGreaterEqual(s.count('await cleanupFailure('), 5)
    def test_outer_uses_inner_trace_and_logger(self):
        s = src('TrackingRefreshService.swift')
        self.assertIn('trace: trace)', s)
        self.assertIn('trace.failureStage', s)
        self.assertIn('var diagnosticLog: DiagnosticLog = .shared', s)
    def test_service_regressions_drive_real_error_paths(self):
        s = (ROOT / 'ParcelKeeperTests/DiagnosticChainTests.swift').read_text()
        for token in ['testNewQueuedBudgetIsWaitNotSaveAndRetainsJob',
                      'testNewJobCancellationAfterSaveIsWaitNotSave',
                      'testJobGoneErrorAndCooldownCleanupFailurePreserveOriginal',
                      'testPollingGoneCleanupFailureKeepsPollStageWithoutRepost',
                      'testRetiredBackendBatchPreservesPendingJobWithoutPolling',
                      'testRetiredBackendDoesNotEnterCooldownCleanup',
                      'testRetiredBackendReportsUnsupportedWithoutNetwork',
                      'testSyncStaleMergerIsAssociationNotLease',
                      'acquireTrackingQuery', 'refreshPending()', 'syncKDYZM(']:
            self.assertIn(token, s)
    def test_trace_thread_safe_holder(self):
        s = src('DiagnosticLog.swift')
        self.assertIn('DiagnosticTrace: @unchecked Sendable', s)
        self.assertIn('NSLock()', s)
        self.assertIn('failureStage', s)
if __name__ == '__main__': unittest.main()

