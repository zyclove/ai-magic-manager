# Batch-picker cursor recovery candidate

Status: **STATIC_CANDIDATE_UNRUN**. Exactly one production file is proposed. Main remains SHA256 `9efcda7088e2937a6d63a3375b2195f239567c94631acb17158e25342eb6feea`; `before.dart` is its raw copy. Candidate SHA256: `2713b6f7fca00461f6929e91ea8267d3009708e1181f5c4a102843febeecf264`. No SDK, test, formatter, build, rendering, code parser, candidate import or execution was performed. No Main/Git or sealed source snapshot was written.

## Minimal behavior

- Only an append request rejected with `ApiFailure.code == INVALID_CURSOR` clears its cursor and sets `cursorInvalid` (222-225). Loaded rows and selection stay visible. Ordinary append errors keep the original cursor and selection for the existing retry; first-page failures retain first-page retry.
- Every ordinary `load` entry rejects while `cursorInvalid` is true (184). This includes a previously captured generic retry callback that would otherwise see the cleared cursor and silently start a first page while retaining old selection.
- The known invalid-cursor branch uses one Notice and one explicit **重新加载并清空选择** button (320-330). It removes generic retry, duplicate warnings/raw technical-code output and load-more for this state. Other ordinary or unknown errors retain FailureView. The copy says pagination cannot continue; it does not say that already loaded records or their identities are invalid.
- `reloadFromStart` rechecks current route/access, not-loading and still-invalid cursor (235-245). In one synchronous state update it clears selection, rows, cursor, error and selected-only mode, then starts the first page. Existing search text remains available, with its existing clear control. Loading locks synchronously in `load`, so repeated activation cannot create duplicate reads. A held reload callback after a successful fresh page cannot clear newly selected rows because the invalid flag is already false.
- Old checkbox callbacks during reload see an empty current `devices` list and fail the unchanged `selectable` check. Confirmation still requires each selected ID/registration to belong to the current loaded devices, active state for add, cap 50 and current owned route/access. No discarded old selection is silently returned.

## Retaining already loaded selection

Invalid pagination does not itself establish that previously loaded device IDs or registrations changed. The user may finish selecting among those loaded records and continue to the existing complete confirmation. `confirm`, `selectable`, OwnedDialogRoute, permission/generation handling and request construction are unchanged. The actual mutation still uses the same captured registration IDs, group version and idempotency key and is atomically checked by the existing API. Restarting browsing instead explicitly clears the old selection; no extra confirmation dialog is added.

## Static scenario trace / not executed

The source was traced for: transient append error -> same-cursor retry; invalid append cursor -> no ordinary load or more; invalid state with retained valid selection -> confirmation remains guarded; explicit reload -> cleared state before the first await; stale generic retry while invalid -> rejected; duplicate or stale reload after success -> rejected; stale row callback before new data -> rejected; first-page failure -> first-page retry; current/permission loss or covered route -> action rejected; cancel during read -> existing owned-route completion and late-read guards. These are text traces, not test results.

All those scenarios, existing tests, and short-screen/large-text rendering remain **UNRUN**. No test source, API, request key, selection cap, selector, timeout or execution framework changed. Root and an independent reviewer should inspect the sealed patch before any application or later separately authorized validation.
