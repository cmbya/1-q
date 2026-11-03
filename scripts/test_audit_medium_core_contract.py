"""Offline source contracts only: not Swift compilation or runtime/XCTest evidence."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
def service(name):
    return (ROOT / 'ParcelKeeper/Services' / (name + '.swift')).read_text()

class AuditMediumCoreContract(unittest.TestCase):
    def test_logistics_cannot_reopen_manual_completion(self):
        refresh = service('TrackingRefreshService')
        shortcut = service('ShipmentShortcutService')
        self.assertIn('if current.status != oldStatus, current.status == .delivered', refresh)
        self.assertNotIn('isCompleted = completed', refresh)
        self.assertIn('if shipment.status != previousStatus,', shortcut)
        self.assertIn('shipment.status == .delivered || shipment.status == .archived', shortcut)
        self.assertNotIn('isCompleted = becomesCompleted', shortcut)

    def test_phone_lifecycle_invalidates_before_secret_write(self):
        cache = service('PaidTrackingCache')
        self.assertIn('func mutatePhone(', cache)
        mutation = cache.split('func mutatePhone(', 1)[1].split('private func validateIdentity', 1)[0]
        self.assertLess(mutation.index('try keys.delete()'), mutation.index('try mutation()'))
        self.assertIn('guard try keys.read() == nil', mutation)
        phones = service('ShipmentPhoneStore')
        self.assertEqual(phones.count('cache.mutatePhone('), 2)
        self.assertIn('let unchanged = try read(for: shipment) == phone', phones)
        self.assertNotIn('locked', mutation)
        shared = service('SharedPickupStore')
        self.assertIn('try clear(identity.shipment)', shared)

    def test_completed_job_rejection_clears_outside_rolled_back_transaction(self):
        source = service('KDYZMSync')
        terminal = source.split('let snapshot = try await client.snapshot', 1)[1]
        self.assertIn('catch {', terminal)
        self.assertIn('try await clearJob(expectedID, before: before, credential: credential)', terminal)
        self.assertIn('throw await cleanupFailure(error,', terminal)
        self.assertIn('if original is CancellationError { return original }', terminal)
        self.assertIn('originalReason: originalReason, originalStage: originalStage, cleanupReason: cleanupReason', terminal)
        self.assertIn('data.shipments[i].backendRefreshGeneration == (before.backendRefreshJobID == id ? before.backendRefreshGeneration : credential.generation)', source)
        self.assertIn('data.shipments[index].backendRefreshGeneration == credential.generation', source)
        self.assertEqual(source.count('method: "POST"'), 1)
        self.assertIn('终态任务已清除', source)

    def test_runtime_regressions_are_declared_not_executed_here(self):
        source = (ROOT / 'ParcelKeeperTests/AuditMediumCoreTests.swift').read_text()
        self.assertEqual(source.count('    func test'), 9)
        for token in ['testPhoneSavesAndClearRetireLegacySecretsWithoutCacheAccess', 'testAppDeleteClearsBothSecrets',
                      'testLegacySecretDeletionRequiresSuccessfulEmptyReadback',
                      'testPhoneDeletionFailureFailsClosed', 'testFailedPhoneSaveAlreadyInvalidates',
                      'testOldMainAppButtonRejects', 'testTerminalOldConflictAndNewJobRace',
                      'testShortcutNeverReopens', 'testRefreshPreservesManualCompletion']:
            self.assertIn(token, source)
        self.assertIn('XCTAssertEqual(try store.exportBackup(), before)', source)
        self.assertIn('XCTAssertThrowsError(try cache.lookup(old))', source)
        self.assertIn('transport.requests.allSatisfy { $0.httpMethod == "GET" }', source)

    def test_main_app_passes_snapshot_and_compares_inside_transaction(self):
        source = service('ShipmentStore')
        method = source.split('func setPickupCompleted(', 1)[1].split('func pendingPickupRecords', 1)[0]
        self.assertIn('expected: PickupRecord? = nil', method)
        self.assertLess(method.index('previous == expected'), method.index('isCompleted = completed'))
        self.assertIn('throw PickupStorageError.staleCompletion', method)
        view = (ROOT / 'ParcelKeeper/Views/PickupView.swift').read_text()
        self.assertIn('completed: !record.isCompleted, expected: record', view)

if __name__ == '__main__':
    unittest.main()
