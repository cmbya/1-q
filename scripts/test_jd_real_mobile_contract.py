"""Source checks only; not Swift or authenticated WebKit execution."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class RealMobileContract(unittest.TestCase):
 def test_same_list_view_drives_pages_before_details(self):
  s=(ROOT/'ParcelKeeper/Services/JDInAppClient.swift').read_text()
  collect=s.split('private func collectOrders',1)[1].split('    func query(',1)[0]
  self.assertIn('maxOrderPages: JDOrderImportPolicy.maxPages',collect)
  read=s.split('    func read(url:',1)[1].split('    private func validateLiveAccount',1)[0]
  self.assertIn('window.__parcelJDNextPage()',read)
  self.assertIn('lastPagingAttempt',read)
  self.assertIn('listCanAdvance',read)
  self.assertEqual(read.count('view.load('),1)
 def test_date_bridge_is_accepted_and_binds_native_identity(self):
  s=(ROOT/'ParcelKeeper/Services/JDInAppClient.swift').read_text()
  bridge=s.split('func userContentController(_ controller:',2)[-1].split('    func webView(',1)[0]
  self.assertIn('body["kind"] as? String == "orderDate"',bridge)
  self.assertIn('JDPageParser.submission(body, orderID: expectedOrder)',bridge)
if __name__=='__main__': unittest.main()
