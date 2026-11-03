# KDYZM snapshot/pickup repair

- Follow-backend routing is decided by `refreshChannel == nil`, not the historical `logisticsSource`. Explicit UAPI/Tmini overrides remain untouched.
- `MallDeliveryState.recipientCollected(latest:) -> Bool` exposes narrow recipient pickup evidence. `resolve` reuses it; station acceptance, requests, negatives, forecasts and conditional text are not pickup facts.
- Only newest timestamped incoming events can prove collection. Existing cache/event age guards remain. At an equal timestamp, explicit collection can repair shipment status without replacing conflicting logistics text, history, source or cache timestamp. Ordinary conflicts still reject.
- `updated` counts actual shipment changes; identical snapshots increment `unchanged` and do not rewrite `updatedAt`. Existing report properties remain available; the message adds an unchanged count.
- Refresh returns true only for a committed shipment transition to delivered, never for manual record completion. Existing delivered returns false. Backend signed/picked never mutates `PickupRecord.isCompleted` or other user-owned record fields.
- Empty/error/no-event snapshots do not change existing shipment status or clear history. New tickets retain the prior behavior of seeding coarse remote signed/arrived status, without completing the pickup record. Terminal refresh still requires nonempty successful events, createdAt and checked/updated freshness; pending-job, credential-generation and network-outside-lock protection remain.

## Verification

`python3 -B scripts/test_kdyzm_pickup_repair_contract.py` was run before implementation: 5 checks, 4 expected failures. After implementation all 5 pass. These are source assertions, not Swift execution.

`ParcelKeeperTests/KDYZMPickupRepairTests.swift` adds real XCTest cases for old paid-source routing, explicit paid overrides, unchanged statistics/timestamps, exact pickup wording, newest-only facts, equal-time conflict safety, empty cache behavior and refresh Bool true/false with mocked transport. No Swift toolchain is installed on this Linux host, so XCTest has not been compiled or executed. No real backend/platform requests, build, commit or push were performed.

The requested test-driven-development Skill was denied by the active daily tier; no alternate access was attempted. Testing proceeded using the explicit delegated RED → GREEN workflow.
