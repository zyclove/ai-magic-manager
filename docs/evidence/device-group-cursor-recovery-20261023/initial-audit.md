# Device-group user-flow static audit r2

Status: **ONE_P2_RECOVERY_GAP**. Source text only; no rendered UI was viewed. SDK, tests, formatter, builds, candidate execution and native/process APIs were not run. Main, Git and sealed snapshots were not written.

Reviewed current source pins: `device_groups_page.dart` SHA256 `a4e951742370b108eece12d852104dfa2e817033ed392e1418234dc44a9a8a57`; `device_group_batch_picker.dart` SHA256 `9efcda7088e2937a6d63a3375b2195f239567c94631acb17158e25342eb6feea`.

## P2: Batch-picker invalid cursor has no in-window restart

After a loaded first page, `load(more:true)` captures `cursor` at 187. Its failure handler at 218-220 records only the error. For an explicit `ApiFailure(code: INVALID_CURSOR)`, the rejected cursor therefore survives. The error's retry callback at 302 calls `load(more: cursor != null)`, and the button at 344-348 also calls `load(more:true)`. Both send the same rejected cursor again. The window exposes no fresh-page reload action; a user must cancel and reopen it to restart browsing. This is a conditional code-path finding, not a reproduced runtime failure or a claim that backend cursors expire with time.

Minimum correction: mark only an append INVALID_CURSOR as requiring restart, clear that cursor, retain loaded rows and selection for inspection, and offer one explicit action which explains that it reloads and clears selection. That action must check current/loading synchronously, clear selection/rows/cursor/error/selected-only filter before requesting the first page, and block stale held checkbox callbacks through the existing selectable check. Normal append failures must keep their cursor and selection for same-page retry. Existing confirmation membership/registration checks, route ownership, generation and 50-device cap must remain.

## Paths with no additional static blocker found

- Empty local search results still expose load-more outside the bounded list when a cursor exists (319-321, 344-348); search scope is explicitly labelled as loaded devices. Clear search and selected-only controls remain reachable.
- Detail-page member pagination already separates append errors, retries the same cursor for transient failures, and provides invalid-cursor refresh. Open/filter/back/access changes reset both pagination error fields and generation guards reject stale responses.
- Complete batch confirmation enumerates every selected row and the dialog is scrollable; request bodies use that same full selection with original version/request key. No rendered 50-row or large-text layout result is claimed.
- Picker cancel remains available during a read, and permission/OwnedDialogRoute/generation checks suppress late results. Confirmation locks busy synchronously before its first await, disables close/submit while committing, and keeps the original request key for uncertain retry. Covered route actions cannot submit or pop a covering route; owned completion targets its own route.

No direct `DeviceGroupBatchPicker` test reference was found in current Guardian test sources. `submit_direct_variant_test.dart:244-274` covers one version-bound archive submission and duplicate-submit lock; it does not cover this cursor recovery. Cursor rejection/restart, same-cursor transient retry, stale held row after restart, scope loss, cancellation during reads, and actual short-screen/large-text rendering remain **UNRUN**. No further product changes were invented or implemented by this audit.
