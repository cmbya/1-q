"""Source seam guards only; run JDPreviewImportTests on Xcode for native behavior."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class JDPreviewMergeContract(unittest.TestCase):
    def test_jd_unverified_status_is_presented_without_schema_change(self):
        model = (ROOT/'ParcelKeeper/Models/Shipment.swift').read_text()
        self.assertIn('var statusDisplayText: String', model)
        for name in ['ParcelKeeper/Views/Components/ShipmentRow.swift', 'ParcelKeeperWidget/PendingShipmentWidget.swift', 'ParcelKeeper/Intents/ShipmentChoiceIntent.swift', 'ParcelKeeper/Intents/TrackingRefreshIntents.swift']:
            self.assertIn('shipment.statusDisplayText', (ROOT/name).read_text())
    def test_preview_service_is_local_guarded_and_uses_same_merge(self):
        s = (ROOT/'ParcelKeeper/Services/TrackingRefreshService.swift').read_text()
        self.assertIn('func applyMallPreview(', s)
        body = s.split('func applyMallPreview(', 1)[1].split('func refresh(trackingNumber:', 1)[0]
        for token in ['candidate.jdPreviewResult()', 'acquireTrackingQuery(id: id)', 'withGeneration', 'platformOrderID == candidate.orderID', 'acceptsCarrier', 'backendBinding == nil', 'refreshChannel == nil', 'TrackingQueryHistory.merged', 'current.status == .delivered', 'data.records[linked].isCompleted = true']:
            self.assertIn(token, body)
        for token in ['await', '.query(', 'network.', 'lastQueriedAt >', 'logisticsTime >']:
            self.assertNotIn(token, body)
if __name__ == '__main__': unittest.main()
