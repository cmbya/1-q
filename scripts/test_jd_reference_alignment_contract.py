"""Source seams, not native WebKit or authenticated runtime proof."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class Alignment(unittest.TestCase):
 def test_session_verification_consumes_valid_capture_before_dom_or_paging(self):
  s=(ROOT/'ParcelKeeper/Services/JDInAppClient.swift').read_text()
  loop=s.split('if let captured {',1)[1].split('                if finished {',1)[0]
  self.assertIn('orderID == nil && maxOrderPages <= 1',loop)
  self.assertIn('if captured != nil && orderID == nil',s)
  self.assertIn('JDPageParser.orders(captured)',loop)
  self.assertIn('validateLiveAccount(view)',loop)
 def test_native_preserves_closed_parse_classification(self):
  s=(ROOT/'ParcelKeeper/Services/JDInAppClient.swift').read_text()
  for token in ['.responseDecode','.responseSchema','.scriptProcessing']:
   self.assertIn(token,s)
  reason=(ROOT/'ParcelKeeper/Services/DiagnosticLog.swift').read_text()
  for token in ['responseDecode','responseSchema','scriptProcessing']: self.assertIn(token,reason)
if __name__=='__main__':unittest.main()
