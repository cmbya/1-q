# Recognition repair notes

## Scope and root causes

- Train multiplicity searched the full text and counted gate `C2` as a second train alongside `G123`. Gate-owned tokens are now excluded from train evidence both in the shared local/AI ambiguity guard and local fallback extraction. Only the gate token is removed, not its entire line; repeated journey labels and real second trains still reject.
- English passenger lists (`John Smith; Jane Doe`, including Chinese punctuation) reached the local field reader, which stopped at the semicolon and silently retained one passenger. The full passenger field now rejects explicit list delimiters before parsing or AI dispatch; spaces within a single `John Smith` remain valid.
- Carrier extraction rejected every eleven-digit number beginning with `1`, while manual/JSON validation rejected only mobile-shaped `^1[3-9][0-9]{9}$`. These paths now share the latter rule. Explicit phone/order field ownership remains excluded. Batch import now validates whole tracking tokens instead of sanitizing malformed tokens into another identifier.
- Smart paste parsed the latest logistics event/time but dropped them when creating an import draft; neither save sheet forwarded logistics fields. Drafts now have optional, default-nil `logisticsInfo`, `logisticsTime`, and `queryInfo`, and both save paths forward them. Explicit JSON `queryInfo` is retained; otherwise each isolated parcel's original input is retained as display-only query data. No stored `Shipment` JSON schema or required initializer fields changed.
- Shipment AI previously transmitted text with no eligible tracking token, then necessarily rejected every model response. It now throws `missingNumber` before endpoint/key preparation, network dispatch, or model fallback. Networking protocols/classes are untouched by this repair.
- Formal carrier names without keyword aliases (`快捷速递`, `邮政包裹`) mapped back to unknown and cleared UAPI overrides on unchanged-carrier updates. All formal catalog names now round-trip before aliases; the existing carrier identity/override invalidation policy remains unchanged.
- Bare station/cabinet names previously won over explicit movement (`包裹正在发往驿站`). Specific arrival/custody evidence still maps to pickup, while transport/delivery semantics beat bare destination names. Negations and conditional pickup/completion instructions remain non-completion; actual recipient collection (`收件人凭取件码完成取件`) stays delivered. Existing latest-event ordering, explicit current-status precedence, completed/archived protections and manual completion behavior are untouched.

## Regression coverage

- Added `ParcelKeeperTests/RecognitionRepairTests.swift`: local and AI-entry gate handling, real multiplicity rejection, single/list English passengers, shared tracking/phone/whole-token behavior, draft event/time/query preservation, isolated store persistence and JSON compatibility, status semantics/history rejection, and formal carrier/UAPI override round-trips.
- Extended `ParcelKeeperTests/AIServiceTests.swift`: injected mock AI train response with `G123` + `C2`, passenger-list zero-dispatch rejection, and missing shipment identifier zero-dispatch/no-fallback rejection. No real account/API is used.
- Added `scripts/test_recognition_repair_contract.py`: source contracts plus production-regex/ordered-branch probes. Initial RED run had seven failing tests; after the minimal fixes and additional matrix probes, all eight tests pass.

## Local verification and limits

Passed targeted checks:

```text
python3 scripts/test_recognition_repair_contract.py   # 8 tests
python3 scripts/test_recognition_review_rules.py      # 54 source/regex probes
python3 scripts/test_shortcut_no_time_gate_contract.py # 1 contract test
python3 scripts/test_review_ui_contract.py            # UI source contracts

git diff --check
```

These checks do **not** execute Swift. XCTest additions are **not compiled or run**; no build was attempted, per authorization. Source/regex probes are not a substitute for macOS/iOS tests. No commit/push, real AI/logistics request, configuration change, or user-data mutation was performed. No time threshold or cache policy was introduced or restored. `ShipmentStore.swift` needed no production change because its existing persistence already retains these fields; its boundary is covered by the new isolated XCTest specification.

The current daily skill directory does not include TDD/systematic-debugging skill bodies. No tier upgrade or alternate-file bypass was attempted; this repair followed the requested RED-first regression/minimal-fix workflow directly.
