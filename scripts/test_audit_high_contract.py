"""Offline source contracts only; not execution of Swift or XCTest."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class AuditHighContract(unittest.TestCase):
    def test_instruction_is_not_completed_fact(self):
        source = (ROOT / 'ParcelKeeper/Services/MallDeliveryState.swift').read_text()
        collected = source.split('static func recipientCollected(latest: String) -> Bool {', 1)[1].split('private static func isConditional', 1)[0]
        # Only positive fact literals, not the request/condition exclusion list.
        positive = re.search(r'\|\|\s*\[(.*?)\]\.contains', collected, re.S)
        if positive is None:
            self.fail('Missing explicit recipient/fact classification')
        terms = re.findall(r'"([^"\n]+)"', positive.group(1))
        self.assertIn('guard !["请", "請"', collected)
        self.assertIn('(?:收件人|取件人|本人|客户)凭取件码完成取件', collected)
        self.assertNotIn('"完成取件"', positive.group(1))
        for instruction in ['请凭取件码完成取件', '请尽快完成取件']:
            self.assertFalse(any(term in instruction for term in terms))
        station = source.split('let station =', 1)[1].split('if station', 1)[0]
        self.assertTrue(any(term in '已签收，菜鸟驿站代收' for term in re.findall(r'"([^"\n]+)"', station)))

    def test_paid_queries_do_not_access_legacy_cache(self):
        for name in ['UAPITrackingClient', 'TminiTrackingClient']:
            source = (ROOT / f'ParcelKeeper/Services/{name}.swift').read_text()
            for token in ['cache.identity(', 'cache.lookup(', 'cache.store(']:
                self.assertNotIn(token, source)
            self.assertEqual(source.count('await network.data(for: request)'), 1)

if __name__ == '__main__':
    unittest.main()
