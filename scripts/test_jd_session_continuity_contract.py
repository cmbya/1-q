"""Source guards only; native cookie/session semantics require Apple tests."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class JDSessionContinuity(unittest.TestCase):
 def test_live_cookie_values_are_not_replaced_by_saved_snapshot(self):
  s=(ROOT/'ParcelKeeper/Services/JDInAppClient.swift').read_text()
  self.assertTrue('let existing = await view.configuration.websiteDataStore.httpCookieStore.allCookies()' in s)
  self.assertTrue('existing.contains(where:' in s)
  self.assertTrue('view.configuration.websiteDataStore.httpCookieStore.setCookie(native)' in s)
 def test_navigation_errors_are_fixed_not_raw_webkit_errors(self):
  s=(ROOT/'ParcelKeeper/Services/JDInAppClient.swift').read_text()
  self.assertFalse('failed = error }' in s)
if __name__=='__main__':unittest.main()
