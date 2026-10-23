# Shared EditDialog conflict candidate: independent static review

Conclusion: no production-code blocker found in the frozen r1 single-file patch. Author review has one acknowledged prose correction: non-ApiFailure exceptions clear pendingValues under the unchanged rule; only ApiFailure status 0/5xx preserves it. This review uses that precise boundary. All application scenarios remain UNRUN/unrendered.

## Exact inputs

Candidate `.cache/guardian-edit-dialog-conflict-20261023-r1`: exactly 6 members; 5 delivery descriptors, 4 author-source descriptors and 9 dependency descriptors match actual bytes/hash. Before equals Main design.dart and raw Git blob `6dcf9343f51b545bada95c4618ee8e98eedc9b35` at HEAD `7cf2b2b9960db98f90a7f7630ae967e3ea99eba8`. Recreating the complete 8-hunk unified diff reproduces the delivered patch byte-exact. Everything outside `_EditDialogState` is byte-identical. No author artifact or Main was changed.

## Source reasoning

- After 459–488: save checks `versionConflict` before validation, clearing error, constructing/requesting content or dispatch. The actual prior `pendingValues` is captured at 480–482 before the existing known-error clear at 484–485; its unmodifiable Map is the submitted attempt, including an original body retried after status 0/5xx. A stale saved callback cannot issue another write after 412. Dropdown's held callback also rejects conflict at 553–558.
- After 522–536/612–621: 412 replaces editable fields with labeled option-aware SelectableText and a close-only action. It does not fetch a new version, replay a draft, reset an idempotency key, or emit a refresh/saved marker. `cancel` still calls parameterless `finish`; the form result is null on closure. Non-null result remains confined to the unchanged successful await path at 477–478 (`result ?? submitted`).
- Api.send 260–291/300–318 is unchanged: signature includes method/path/version/body/clientRequestId; key signature blocks changed pending submissions, request carries original If-Match/Idempotency-Key, and a received status below 500 clears the pending key before 412 is thrown. Status 0/5xx keeps both API pending signature and EditDialog pending body; existing locked fields, retry label and original onSubmit closure are retained. Non-ApiFailure clearing is unchanged and is not claimed to preserve an unknown submission.
- Access observation/current/finish/cancel and lifecycle code are unchanged. `!permitted` at after 494 takes precedence over the conflict UI and hides the draft. The original close path uses the captured Owned route; OwnedDialogRoute 19–28 completes/removes only itself even under cover. A legally sent successful save still finishes its own dialog without popping a cover; conflict/cancel does not pretend to succeed. No new listener or route lifecycle was introduced.

## Existing coverage and limits

Read-only existing source: api_test 58–76 asserts one 412 request with version/key/error correlation; widget_test's unknown-submission case asserts status-0 same-content retry and locked input; dialog_submit_guard_test covers queued duplicate save callbacks. These were not executed and do not establish the new 412 UI, held-after-conflict callback, copied draft, scope-loss or covered completion behavior. No new tests or fixes to other forms are included.

Author's original review sentence including non-ApiFailure as retained pending content is inaccurate; the author acknowledged it and is providing a separate erratum while preserving sealed r1. This is documentation scope only, not a request to widen production changes.

Only text/hash/JSON/read-only Git and mechanical text-diff checks were used. No SDK/tests/compiler/formatter/AST/parser/candidate function/predicate/fixtures/process query/network; no Main/Git/candidate/shared-cache write. Future real validation remains required; this is static independent review, not a passing test or runtime acceptance claim.
