"""Offline source assertions only; does not execute Swift or real accounts."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class SnapshotDiagnosticsContract(unittest.TestCase):
    def test_order_scoped_identity(self):
        s=(ROOT/'ParcelKeeper/Services/KDYZMSync.swift').read_text()
        key=s.split('let key = shipment.accountId',1)[1].split('\n',1)[0]
        self.assertIn('shipment.orderId',key)
        self.assertIn('identities.insert(key)',s)
        self.assertIn('try unique(shipments.map(\\.id))',s)
    def test_stages_are_fixed_and_visible(self):
        c=(ROOT/'ParcelKeeper/Services/KDYZMClient.swift').read_text()
        d=(ROOT/'ParcelKeeper/Services/ShipmentStore.swift').read_text()
        for token in ['enum KDYZMSyncFailure', 'case decoding, validation, association, localRead, localWrite, presentation', 'SYNC-DECODE', 'SYNC-VALIDATE', 'SYNC-LINK', 'SYNC-READ', 'SYNC-WRITE', 'SYNC-DISPLAY']:
            self.assertIn(token,c)
        self.assertIn('error as? KDYZMSyncFailure',c)
        self.assertIn('throw KDYZMSyncFailure.decoding',c)
        self.assertIn('throw KDYZMSyncFailure.validation',c)
        self.assertIn('throw KDYZMSyncFailure.association',d)
        self.assertIn('throw KDYZMSyncFailure.localWrite',d)
if __name__=='__main__':unittest.main()
