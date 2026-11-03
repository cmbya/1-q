#!/usr/bin/env python3
"""Targeted source/regex contracts only; does not compile or execute Swift/XCTest."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
S = ROOT / "ParcelKeeper/Services"


def source(name):
    return (S / (name + ".swift")).read_text()


class RecognitionRepairContract(unittest.TestCase):
    def test_gate_tokens_are_not_train_candidates(self):
        train = source("TrainTicketRecognition")
        self.assertIn("static func trainEvidence", train)
        self.assertIn("trainEvidence(text)", train)
        self.assertIn("trainEvidence(evidence)", train)
        match = re.search(r'let gatePattern = #"(.*?)"#', train)
        assert match is not None
        for gate in ["C2", "D12", "G1", "C2、C3"]:
            cleaned = re.sub(match[1], "", "G123 检票口：" + gate)
            self.assertEqual(re.findall(r"[GDCZTKYLS]\d{1,5}", cleaned), ["G123"])

    def test_latin_passenger_lists_reject_before_truncation(self):
        train = source("TrainTicketRecognition")
        match = re.search(r'let passengerListPattern = #"(.*?)"#', train)
        assert match is not None
        # Python stdlib has no Unicode property classes. These fixtures use ASCII names.
        pattern = match[1].replace(r"\p{L}", "A-Za-z")
        for value in ["John Smith; Jane Doe", "John Smith；Jane Doe", "John Smith, Jane Doe", "John Smith/Jane Doe"]:
            self.assertRegex(value, pattern)
        self.assertNotRegex("John Smith", pattern)
        self.assertIn("hasMultiplePassengers($0[1])", train)

    def test_tracking_validation_shares_phone_policy(self):
        carrier, shortcut = source("CarrierDetector"), source("ShipmentShortcutService")
        self.assertIn('pattern: #"^1[3-9][0-9]{9}$"#', carrier)
        self.assertIn("static func isLikelyPhoneNumber", carrier)
        self.assertIn("!CarrierDetector.isLikelyPhoneNumber(value)", shortcut)
        self.assertNotIn("CarrierDetector.sanitize(draft.trackingNumber)", (ROOT / "ParcelKeeper/Views/BatchImportSheet.swift").read_text())
        phone = re.search(r'matches\(value, pattern: #"(.*?)"#\)', carrier)
        tokens = re.search(r'let tokenPattern = #"(.*?)"#', carrier)
        assert phone is not None and tokens is not None
        for number in ["10012345678", "11012345678", "12012345678"]:
            self.assertIsNone(re.search(phone[1], number))
            self.assertEqual(re.findall(tokens[1], number), [number])
        for number in ["13012345678", "13800138000", "19912345678"]:
            self.assertRegex(number, phone[1])
        for bad in ["SF12345678-90123", "SF1234567890123#", "SF1234567890123_", "+SF1234567890123"]:
            self.assertEqual(re.findall(tokens[1], bad), [], bad)

    def test_draft_and_both_save_paths_preserve_logistics(self):
        draft = (ROOT / "ParcelKeeper/Models/ShipmentImportDraft.swift").read_text()
        smart = source("SmartShipmentParser")
        for field, kind in [("logisticsInfo", "String"), ("logisticsTime", "Date"), ("queryInfo", "String")]:
            self.assertIn(f"{field}: {kind}? = nil", draft)
            self.assertIn(f"{field}: parsed.{field}", smart)
            for view, owner in [("AddShipmentSheet", "initialDraft"), ("BatchImportSheet", "draft")]:
                expected = f"{field}: initialDraft.{field}" if view != "AddShipmentSheet" else f"{field}: preservesDraftIdentity ? initialDraft.{field} : nil"
                if view == "BatchImportSheet": expected = f"{field}: draft.{field}"
                self.assertIn(expected, (ROOT / f"ParcelKeeper/Views/{view}.swift").read_text())
        self.assertIn("parsed.queryInfo = context", smart)

    def test_edited_tracking_number_does_not_inherit_original_draft_logistics(self):
        view = (ROOT / 'ParcelKeeper/Views/AddShipmentSheet.swift').read_text()
        self.assertIn('let preservesDraftIdentity = normalized ==', view)
        self.assertIn('ShipmentShortcutParser.number(initialDraft.trackingNumber)', view)
        for field in ['logisticsInfo', 'logisticsTime', 'queryInfo']:
            self.assertIn(f'{field}: preservesDraftIdentity ? initialDraft.{field} : nil', view)

    def test_missing_tracking_number_fails_before_network_or_fallback(self):
        body = source("AIService").split("func extractShipment(", 1)[1].split("func extract(_", 1)[0]
        guard = "guard !numbers.isEmpty else { throw ShipmentShortcutError.missingNumber }"
        self.assertIn(guard, body)
        self.assertLess(body.index(guard), body.index("try request("))
        self.assertLess(body.index(guard), body.index("for model in models"))

    def test_all_formal_carrier_names_resolve_before_keyword_aliases(self):
        carrier = source("CarrierDetector")
        body = carrier.split("static func carrierMentioned", 1)[1].split("static func sanitize", 1)[0]
        self.assertIn("allCarriers.first", body)
        self.assertIn("$0 != unknown", body)
        self.assertLess(body.index("allCarriers.first"), body.index("for (carrier, keywords)"))

    def test_status_regex_and_branch_fixture_matrix(self):
        body = source("ShipmentShortcutService").split("static func status", 1)[1].split("private static func completionIsConditional", 1)[0]
        rules = []
        # Execute the literal keyword arrays/receipt regex in their Swift order,
        # rather than maintaining independent copies of the production patterns.
        for line in body.splitlines():
            array = re.search(r'if \[(.*?)\]\.contains\(where: text.contains\) \{ return \.(\w+) \}', line)
            receipt = re.search(r'if text.range\(of: #"(.*?)"#.*return \.(\w+)', line)
            if array:
                rules.append((re.findall(r'"(.*?)"', array[1]), array[2]))
            elif receipt:
                rules.append((re.compile(receipt[1]), receipt[2]))
            elif 'if ["未取件", "未完成", "未收货"]' in line:
                rules.append((["未取件", "未完成", "未收货"], "denial"))
            elif "if conditionalCompletion" in line:
                pattern = source("ShipmentShortcutService").split("private static func completionIsConditional", 1)[1].split('text.range(of: #"', 1)[1].split('"#', 1)[0]
                rules.append((re.compile(pattern), "readyForPickup"))
        def classify(text):
            for pattern, state in rules:
                if (any(term in text for term in pattern) if isinstance(pattern, list) else pattern.search(text)):
                    if state == "denial":
                        return "readyForPickup" if any(term in text for term in ["驿站", "快递柜", "丰巢", "代收点", "代收", "取件码"]) else None
                    return state
            return None
        for text, expected in [
            ("包裹正在发往驿站", "inTransit"), ("运输中，目的地为快递柜", "inTransit"),
            ("快递员派送中，目的地为驿站", "outForDelivery"), ("已到达菜鸟驿站", "readyForPickup"),
            ("已签收，快递柜代收", "readyForPickup"), ("请凭取件码完成取件", "readyForPickup"),
            ("若已完成取件请忽略", "readyForPickup"), ("未完成取件，取件码未使用", "readyForPickup"),
            ("收件人凭取件码完成取件", "delivered"), ("本人签收", "delivered"),
        ]:
            self.assertEqual(classify(text), expected, text)

    def test_transport_and_conditional_completion_are_not_station_receipts(self):
        body = source("ShipmentShortcutService").split("static func status", 1)[1].split("static func date", 1)[0]
        self.assertIn("let conditionalCompletion", body)
        self.assertIn("if conditionalCompletion", body)
        transport = 'if ["运输中", "转运", "已发出", "已揽收", "已到达", "正在发往"]'
        self.assertIn(transport, body)
        self.assertLess(body.index(transport), body.index('if ["驿站", "快递柜"'))
        self.assertLess(body.index("if conditionalCompletion"), body.index('"已领取", "已取件", "已收货", "完成取件"'))


if __name__ == "__main__":
    unittest.main(verbosity=2)
