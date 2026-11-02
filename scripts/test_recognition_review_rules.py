#!/usr/bin/env python3
"""Source/regex probes only; NOT Swift execution or XCTest replacement."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SERVICES = ROOT / "ParcelKeeper/Services"

def raw_assignment(source, name):
    match = re.search(r'let ' + name + r' = #"(.*?)"#', source)
    assert match is not None, name
    return match.group(1)

carrier = (SERVICES / "CarrierDetector.swift").read_text()
excluded = raw_assignment(carrier, "excludedPattern")
checks = 0
for opening, closing in [("(", ")"), ("（", "）"), ("[", "]"), ("【", "】"), ("「", "」"), ("『", "』")]:
    for label in ["订单号", "訂單號", "订单编号", "ORDERID"]:
        text = f"{label}：{opening}AB123456{closing} 运单号：SF1234567890123"
        spans = [m.span() for m in re.finditer(excluded, text)]
        assert any(start <= text.index("AB123456") < end for start, end in spans)
        assert not any(start <= text.index("SF1234567890123") < end for start, end in spans)
        checks += 1
    assert not re.search(excluded, f"运单号：{opening}AB123456{closing}")
    checks += 1

train = (SERVICES / "TrainTicketRecognition.swift").read_text()
names_match = re.search(r'nonTravelTimeNames = "(.*?)"', train)
assert names_match is not None
names = names_match.group(1)
day = raw_assignment(train, "day")
time = raw_assignment(train, "time")
# Same concatenation as Swift's splitTimestamp, evaluated with Python's regex engine.
pattern = (r"(?m)^[ \t]*" + names + r"[ \t]*[:：][ \t]*(?:\r?\n[ \t]*)+" + day
           + r"(?:(?:[ T]+|(?:\r?\n[ \t]*)+)" + time + r")?[ \t]*(?=\r?$|\n)")
for label in ["下单时间", "订单日期", "支付时间", "出票日期", "购票时间"]:
    for value in ["2026-10-31", "2026-10-31\n08:00", "2026-10-31 08:00"]:
        text = f"{label}：\n{value}\n出发日期：2027-01-01\n车次：G123"
        evidence = re.sub(pattern, "", text)
        assert "2026-10-31" not in evidence
        assert "08:00" not in evidence
        assert "出发日期：2027-01-01" in evidence
        checks += 1
assert re.sub(pattern, "", "2026-10-31\n车次：G123") == "2026-10-31\n车次：G123"
checks += 1

pickup = (SERVICES / "PickupTextParser.swift").read_text()
loop = pickup.split("for match in codeMatches {", 1)[1].split("// Only consume", 1)[0]
assert loop.index("codeOccurrences += 1") < loop.index("validWrapping") < loop.index("codes.append")
assert loop.index("PickupFieldProtection.allows") < loop.index("codeOccurrences += 1")
identity = (ROOT / "ParcelKeeper/Models/TrainTicket.swift").read_text()
assert "departureTime, trainNumber.uppercased()," in identity
assert "result.trainNumber =" not in identity
smart = (SERVICES / "SmartShipmentParser.swift").read_text()
assert "contexts.compactMap" not in smart
assert "catch {\n                failures.append" in smart
assert "return report.hasFailures ? [] : report.drafts" in smart
assert "return ParseReport(drafts: drafts, failures: failures)" in smart
checks += 8
print(f"PASS: {checks} source/regex probes. Swift/XCTest NOT executed; no build performed.")
