"""Offline source/JS checks only; native regression tests require Xcode."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class JDDiagnosticsContract(unittest.TestCase):
 def test_jd_operations_log_page_and_parse_stages(self):
  s=(ROOT/'ParcelKeeper/Services/JDInAppClient.swift').read_text()
  for token in ['JDDiagnostics', '.jdVerify', '.jdFetch', '.jdQuery', '.jdOrdersParse', '.jdLogisticsParse', '.jdCookieInjection', '.jdPageDOM', '.httpStatus', '.jdBridgeRejected']:
   self.assertTrue(token in s, token)
 def test_safe_diagnostic_api_cannot_accept_raw_error_text(self):
  p=ROOT/'ParcelKeeper/Services/JDDiagnostics.swift'
  self.assertTrue(p.exists(), 'missing JD diagnostics helper')
  s=p.read_text()
  self.assertIn('NSURLErrorDomain',s)
  self.assertIn('safeNetworkCode',s)
  self.assertNotIn('localizedDescription',s)
  self.assertNotIn('userInfo',s)
 def test_jd_login_save_is_traced(self):
  s=(ROOT/'ParcelKeeper/Views/MallImportView.swift').read_text()
  for token in ['jdDiagnostics', '.jdLogin', '.jdSessionSave', 'jdDiagnostics?.fail(error)', '.httpStatus']:
   self.assertTrue(token in s, token)
if __name__=='__main__':unittest.main()
