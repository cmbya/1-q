"""Source checks only: native cookie behavior must also run in XCTest."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class CookieAttributeContract(unittest.TestCase):
 def test_cookie_attributes_survive_reinjection(self):
  s=(ROOT/'ParcelKeeper/Services/TaobaoTrial.swift').read_text()
  self.assertIn('var httpOnly: Bool? = nil',s)
  self.assertIn('func webCookie() -> HTTPCookie?',s)
  self.assertIn('HTTPCookiePropertyKey("HttpOnly")',s)
  self.assertIn('if httpOnly == true',s)
  self.assertIn('.secure: secure ? "TRUE" : "FALSE"',s)
  self.assertIn('properties[.expires] = expires',s)
if __name__=='__main__': unittest.main()
