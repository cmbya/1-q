"""Static source contracts only; not Swift/AppIntent execution."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class AuditLowContract(unittest.TestCase):
    def test_reset_checks_selection_and_mode_inside_transaction(self):
        source = (ROOT / 'ParcelKeeper/Services/PendingShipmentSelection.swift').read_text()
        reset = source.split('func resetPendingShipmentBrowsing', 1)[1]
        self.assertIn('expected: PendingShipmentSelection.Identity? = nil', reset)
        self.assertIn('try transaction', reset)
        self.assertIn('guard let expected', reset)
        self.assertIn('PendingShipmentSelection.identity(in: data) == expected', reset)
        self.assertLess(reset.index('guard let expected'), reset.index('data.pendingShipmentBrowsingID = nil'))

    def test_widget_serializes_mode_and_id_and_rejects_legacy_parameters(self):
        source = (ROOT / 'ParcelKeeperWidget/PendingShipmentWidget.swift').read_text()
        reset = source.split('struct ResetPendingShipmentIntent', 1)[1].split('struct PendingShipmentWidgetView', 1)[0]
        self.assertIn('var expectedBrowsing: Bool?', reset)
        self.assertIn('let browsing = expectedBrowsing', reset)
        self.assertIn('UUID(uuidString: expectedID)', reset)
        self.assertIn('expected: .init(selectedID: id, browsing: browsing)', reset)
        self.assertIn('ResetPendingShipmentIntent(id: entry.shipment?.id, browsing: entry.browsing)', source)

    def test_phone_test_fixtures_never_use_default_cache(self):
        for path in (ROOT / 'ParcelKeeperTests').glob('*.swift'):
            for call in re.findall(r'ShipmentPhoneStore\(keys: [^\n]+', path.read_text()):
                self.assertIn('cache:', call, str(path))
