"""Source contracts only; real Swift behavior is covered by XCTest on Apple hosts."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
STORE = (ROOT / 'ParcelKeeper/Services/SharedPickupStore.swift').read_text()
INTENTS = (ROOT / 'ParcelKeeperWidget/TrainTicketWidgetIntents.swift').read_text()
WIDGETS = (ROOT / 'ParcelKeeperWidget/TrainTicketWidgets.swift').read_text()

class StoreWidgetIdentityContract(unittest.TestCase):
    def test_browse_checks_full_binding_under_lock(self):
        body = STORE.split('func browseTrainWidget(', 1)[1].split('func resetTrainWidgetBrowsing', 1)[0]
        self.assertIn('expectedBinding: TrainWidgetBinding? = nil', body)
        self.assertIn('expectedBinding.slot == slot', body)
        self.assertIn('binding == expectedBinding', body)
        self.assertLess(body.index('try transaction'), body.index('binding == expectedBinding'))
        self.assertIn('current?.id == expectedTicketID', body)

    def test_intent_and_both_buttons_carry_binding(self):
        body = INTENTS.split('struct ResetTrainTicketWidgetBrowsingIntent', 1)[0]
        self.assertIn('@Parameter(title: "当前绑定快照") var expectedBinding: String?', body)
        self.assertIn('JSONDecoder().decode(TrainWidgetBinding.self', body)
        self.assertIn('expectedBinding: binding', body)
        self.assertEqual(WIDGETS.count('expectedTicketID: entry.ticket?.id, expectedBinding: entry.binding'), 2)

    def test_import_checks_internal_and_existing_cross_entity_ids(self):
        self.assertIn('try validateImportIdentifiers(incoming, against: incoming)', STORE)
        self.assertIn('try validateImportIdentifiers(incoming, against: current)', STORE)
        helper = STORE.split('private func validateImportIdentifiers', 1)[1].split('private func write', 1)[0]
        for field in ['other.groups', 'other.records', 'other.shipments', 'other.trainTickets', 'incoming.trainTickets', 'r.shipmentID != $0.id', '$0.shipmentID != s.id']:
            self.assertIn(field, helper)
        preview = STORE.split('func previewBackup', 1)[1].split('func importBackup', 1)[0]
        self.assertLess(preview.index('validateImportIdentifiers(incoming, against: incoming)'), preview.index('return BackupPreview'))

if __name__ == '__main__':
    unittest.main()
