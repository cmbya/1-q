"""Offline source contracts only; not execution of Swift or XCTest."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class AuditHighContract(unittest.TestCase):
    def test_instruction_is_not_completed_fact(self):
        source = (ROOT / 'ParcelKeeper/Services/MallDeliveryState.swift').read_text()
        collected = source.split('let collected =', 1)[1].split('if collected', 1)[0]
        # Only positive fact literals, not the request/condition exclusion list.
        positive = re.search(r'return recipientCollected \|\| \[(.*?)\]\.contains', collected, re.S)
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

    def test_force_still_reads_cache_before_dispatch(self):
        for name in ['UAPITrackingClient', 'TminiTrackingClient']:
            source = (ROOT / f'ParcelKeeper/Services/{name}.swift').read_text()
            query = source.split('let identity = try cache.identity', 1)[1]
            before_dispatch = query.split('network.data(for:', 1)[0]
            self.assertNotIn('if !ignoreCache, let cached = try cache.lookup', before_dispatch)
            self.assertRegex(before_dispatch, r'let cachedResult = try cache.lookup\(identity\)')

if __name__ == '__main__':
    unittest.main()
