# Refresh repair notes

## Changes

- Production UAPI uses `UAPIBoundedNetwork`, not AI's buffered transport. The isolated ephemeral session has no shared cookies/cache, refuses every redirect, checks declared length, caps cumulative bytes at 2,000,000 (including unknown-length streams), and cancels on overflow/cancellation. Session lifetime is request-scoped. `AINetworking` injection and a post-download defensive parser bound remain available.
- Added a secret-free, non-Codable `UAPIConfiguration` generation token. The production client exposes a protocol-dispatched atomic `withConfiguration` guard that shares the settings mutation lock, enclosing the dataset transaction rather than merely checking inside it. No lock spans network awaits. Disable/remove/replace invalidates both late results and diagnostic writes. Existing injected synthetic clients remain source compatible via default protocol witnesses.
- Query histories now use a flat, ordered, exact-line union. Paid/platform refreshes retain prior cross-source detail; backend rebuilds capture intermediate non-backend history, merge backend nodes, flatten the legacy `【原有历史】` marker, and deduplicate without recursively nesting aggregates. Unchanged backend repeats do not rearchive their own generated history.
- Kept event/query timestamp replacement behavior without an old/new gate. Kept UAPI usage snapshot request-start ordering: usage accounting is not a logistics freshness gate.
- Report compatibility fields remain route-attempt ticket counts. Copy explicitly includes local preflight failures and disclaims actual request/billing counts.
- Updated the obsolete KDYZM older-response test to expect application of valid older logistics; failed and empty responses still preserve all data.

## Regression coverage and evidence

- Added `scripts/test_refresh_repair_contract.py` before production changes: initial run failed all seven cases (5 failures, 2 missing-definition/file errors). After repair all seven pass.
- Focused existing source contracts: 15 KDYZM contracts and 3 refresh-outcome contracts pass. `git diff --check` passes.
- Added `UAPIBoundedNetworkTests.swift` using synthetic URLProtocol bytes at an `.invalid` host, with exact cap/unknown length overflow, oversized Content-Length, no global cookie/cache and same/cross-origin redirect delegate coverage. Tests do not use a real query endpoint.
- Extended UAPI tests for settings changes during an injected response and rejection of retired commit tokens without running the write. Existing usage-snapshot ordering regression remains intact.
- Linux has no `swift` executable; **no Swift compilation, XCTest, Xcode build, native transport execution or device run was performed**. XCTest definitions still require Apple/Xcode execution.
- The requested TDD/systematic-debugging Skills are not in the current allowed daily Skill directory. No tier upgrade, alternate entrypoint or filesystem bypass was attempted. Work followed source-level red → fix → green plus regression definitions, not an unavailable Skill body.

## Integration follow-up for parent review

- Existing `scripts/test_network_refresh_no_time_gates_contract.py` splits on the literal `let delivered = try store.transaction` and demands literal `current.queryInfo = result.queryInfo`. Its first case must be updated for the outer atomic `commitResult` and flat history merge; the underlying no-time-gate behavior is retained. This file was deliberately not edited by this workstream.
- No commit, push, build, real API/account/SMS operation was used. Only the assigned refresh/UAPI/KDYZM files and dedicated new tests/docs/contracts were edited by this workstream.

