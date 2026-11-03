"""Source checks only, not Swift runtime verification."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class ShortcutNoTimeGate(unittest.TestCase):
 def test_upsert_has_no_saved_time_gate(self):
  s=(ROOT/'ParcelKeeper/Services/ShipmentShortcutService.swift').read_text().split('@discardableResult func upsert(',1)[1]
  self.assertFalse('throw ShipmentShortcutError.olderUpdate' in s, 'older timestamp still blocks shortcut')
  self.assertFalse('shipment.logisticsTime != nil && value.logisticsTime == nil' in s, 'undated result still blocked')
  self.assertIn('shipment.logisticsTime = value.logisticsTime',s)
  self.assertIn('matches.count <= 1',s)
  self.assertIn('state != .delivered && state != shipment.status',s)
if __name__=='__main__': unittest.main()
