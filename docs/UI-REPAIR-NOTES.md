# UI repair notes

## Scope and causes

- Reminder controls were initialized on appearance only. `store.reload()`, foreground reconciliation and backup replacement could update committed dates without updating local controls. State `onChange` handlers also made a programmatic restoration capable of scheduling another reminder.
- Settings checked notification authorization only on its initial task or explicit request. Returning from Settings.app did not re-read permission.
- The app had no foreground notification delegate. Pickup widget open actions had no group destination, and pickup code/location text used fixed 9–14 pt sizes.

## Changes and safety boundaries

### Reminder state

User-only `Binding` setters now initiate reminder writes. Programmatic state synchronization/restoration has no scheduling, cancellation, authorization or persistence side effects. Observe the committed shipment reminder date and the shared operation lock. Automatic synchronization waits until neither local scheduling nor any store reminder operation is running; local operation cleanup also synchronizes explicitly. The latest committed date wins on unlock, including an externally disabled reminder.

Historical snapshots may display their stored reminder state but remain disabled/read-only, with the existing write guard and compensation retained. Existing backup/launch/foreground reconciliation is preserved. No shipment storage, completion rules, refresh time gates or caches were added/changed by this UI patch.

### Notifications

The process-lifetime `NotificationManager.shared` implements `UNUserNotificationCenterDelegate`; App initialization registers it. Foreground presentation requests banner/list/sound exactly once through the completion handler. Registration itself never requests authorization or schedules a request. Existing reminder reconciliation retains its existing behavior. Settings re-reads authorization when scene phase becomes active, without requesting permission from that refresh.

### Pickup navigation and widgets

- Group destination: `parcelkeeper://pickup/<canonical UUID>` (case-insensitive UUID letters).
- No group/legacy open destination: exactly `parcelkeeper://pickup`.
- Reject missing/malformed IDs, extra/trailing path segments, percent-encoded UUIDs, query/fragment, credentials and port. Do not sanitize or repair parameters.
- App reloads before resolving membership. A deleted group safely opens all pickup groups; subsequent deletion also falls back to the full group list. The focused list offers “查看全部分组”. Each open resets stale search/completed filters. Existing `train` and `shipments` routes remain unchanged.
- Existing open AppIntent accepts an optional group UUID string for backward-compatible decoding, validates it, then returns `OpenURLIntent`; code/location buttons and widget background carry the destination. Completion is still a separate action with its original record snapshot validation.
- All normal A–J slots use the same repaired `PickupWidgetView`; no slot definitions changed. Semantic Dynamic Type fonts replace fixed sizes and shrinking. Row capacity decreases for large/accessibility sizes; hidden counts remain visible, with VoiceOver labels/hints and privacy markings retained.

## Verification performed here

- TDD: new `scripts/test_ui_repair_contract.py` initially failed all 7 contracts; after minimal repairs all 7 passed.
- New `ParcelKeeperTests/UIRepairTests.swift` covers strict URL inputs, foreground presentation policy, and external reminder reload while preserving explicit pickup completion. It uses temporary storage and no live notification scheduling. These XCTest cases have **not** been compiled or run here.
- Targeted checks passed: `test_ui_repair_contract.py`, `test_audit_medium_ui_contract.py`, `test_audit_high_contract.py`, `test_audit_low_contract.py`, `test_store_widget_identity_contract.py`, `test_paid_cache_contract.py`, `test_review_ui_contract.py`, plus `git diff --check`.
- Only targeted offline Python/source checks and `git diff --check` are used in this Linux environment. Source contracts are not Swift execution or device/UI validation. Parent agent owns the full check suite.
- No Swift build/compiler, real reminder writes, account/network login, commits or pushes were performed.
- Requested TDD/systematic-debugging skills were not present in the allowed current skill directory; no tier upgrade or filesystem bypass was used. Root-cause tracing and RED→GREEN were performed directly.

## Follow-up on an authorized Apple test environment

1. Open an existing detail, externally enable/change/disable its reminder, reload, and verify no extra system write from synchronization; repeat during scheduling, denied permission, failed-save compensation and reconciliation. Verify historical snapshot remains read-only.
2. Toggle notification permission in Settings.app, return to visible app settings, and confirm current status. With previously granted permission, verify foreground delivery produces banner/list/sound subject to iOS/Focus policy.
3. Verify A–J small/medium/large widgets at default, XXXL and largest accessibility sizes with long codes/locations, VoiceOver and hidden-row counts.
4. Open each widget group while the app is cold/warm, currently on train/settings, or filtered to completed/search. Delete a bound group and retry. Verify malformed URLs do nothing, root opens all groups, completion never opens/completes another record, and train/shipments links still work.

