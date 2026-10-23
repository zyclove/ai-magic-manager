# Independent delta and full-patch review: QuotaPage r2

Conclusion: STATIC_NO_BLOCKER for the exact Page r2 refinement and its retained r1 page/host design. All application scenarios remain UNRUN and rendering is NOT_OBSERVED. This report does not accept the Editor, the authored Plans candidate, ResourcePage.canInteract or the assembled six-file runtime bundle. No candidate source was executed or modified.

## Fixed artifacts and actual checks

Baseline HEAD: `bb93c0b0bacfea622e50828e635aa61d738f342b`.

- r2 after.dart: 16985B, SHA256 `8d5473a890547ea6d003f687305698fa9b1a300dec297aafe3c253e781f481b8`.
- Host after remains 87508B, SHA256 `0b1ee926b5f73f4c79862778dc831953ae82bf4858136a458bdaf1891bdc30a7`.
- Full combined patch: 32238B, SHA256 `19d5a74a9b76d85da6954d35d2d325536304d65d5635da0ee76d2c33c0b52186`.
- pins.json: 3158B, SHA256 `4834eefa4670b574046ad6c423d880a2a9269e765e3a2074f674202771db13b6`.
- delivery.json: 1148B, SHA256 `9b45bb1a47de2b35df1c7a5002abcdeeb0d7d852ba6356f10521f95b4936fc64`.

Own text/byte readback `ef28c8` exited naturally 0. All five declared identities, six files in pins, seven delivery descriptors, six baseline dependency pins and exact eight-file membership matched. Both Main raw before images matched. The complete mixed-newline two-file patch reconstructed byte-for-byte from Main before to r2 after. Before, host-before, host-after and baseline dependency metadata are identical to r1.

A pure literal reconstruction of r1 -> r2 matched the entire r2 after source: only the advertised detail adjustment action and adjust return-type/result statements differ. This was text comparison, not Dart AST/parsing, compilation, candidate execution or business-predicate evaluation. The original r1 independent report SHA `e55a6587762be622fb310dd6bb8895704159ff5b6f906c947fc58bf68cee65a2` and its pinned input artifacts were reread and remained unchanged. The r1 report keeps its historical cancel-return-to-list observation; this new report documents its intentional replacement.

## Refined interaction and result flow

### Before awaiting the adjustment

r2 after.dart:276-284 captures the actual initiating detail route from dialogContext and rejects an invalid original access binding, a non-Owned<void> route, an unavailable route or a covered route before invoking adjust. The real shared details helper already synchronously locks its action and checks currentness, and the explicit action guard independently binds the captured completion target. A stale handler cannot start a new adjustment under a cover or after the original detail has finished.

### Adjustment returns the actual shared form result

adjust now returns Future<Json?> (after.dart:291). Rejected entry or invalid journey returns null (:292,301). It returns await formDialog (:303) while preserving the existing try/finally cleanup of its journey scope and binding. formDialog's existing signature is Future<Json?>; its normal cancellation yields null, while a successful form submission returns its Json result. No wrapper invents a successful value on cancellation.

The shared form behavior and all validation/payload code remain unchanged. The text delta does not touch POST endpoint, requestId, If-Match version, direction/reason, minute bounds/conversion, date range, identity or uncertainty retry. The finally block executes for both results. The action's later access check refers to the original OUTER detail/page binding, not the just-disposed inner adjustment binding, so valid completion is not accidentally rejected by its own cleanup.

### Cancellation now retains the original details

DetailAction explicitly sets closeOnSuccess:false. When adjust returns null, the completion branch does not call route.finish and the shared action helper no longer automatically closes the details. Its finally releases busy, leaving the same detail route available for a new action or close. The normal containing ResourcePage action future still belongs to those details and only completes when those details eventually finish. No premature list refresh is added by this refinement.

This is the deliberate r2 UX change: cancel-adjust now returns to the same details instead of the list. It is source-backed intent, not a rendered or keyboard/back behavior verification.

### Successful completion finishes only the original detail, including while covered

After await, after.dart:281-282 requires non-null result, the original access still permitted and the captured route still available, then calls its own finish. It intentionally does not require post-await isCurrent. Thus a legitimate accepted form save completed under an unrelated cover can end its own form and original detail while preserving that cover. OwnedDialogRoute.finish already removes only its own route when covered.

If the original detail was closed externally, route.available is false and it does not finish a later route. If original page/Session access was revoked, outer binding is false and the result does not bless a new owner. The captured route cannot be finished a second time. Returning through the original shared details action/ResourcePage still permits its necessary internal refresh; no user-interaction top-route guard was added to that accepted-result path.

## Retained scope, helper and source boundaries

All non-refinement page/host text is exact r1. The r1 independent findings about original owner capture, ancestor binding before awaits, lifetime immediate invalidation/deferred concealment, scoped reads, separate canInteract, owned ledger, safe revoked close and host five-part key therefore retain the same source basis. This report does not redo or broaden that audit, nor imply unrelated siblings passed.

The shared ViewLifetime input is unchanged at 1068B/SHA `c68c7457f2cd212df0b8d34b727c8e07364b6605832c41dc133d70355d719815`. Original QuotaPage before still has 303 CRLF lines and after remains LF (the r2 text adds six lines over r1). The normalization remains real; no preservation claim is made. Host is byte-identical to r1 and its sole production change remains the immutable Session/actor/tenant/role/generation key.

## Required later scenarios, all UNRUN

- Open daily details, launch adjustment and cancel via the actual form control: the same original detail/future stays open, action buttons unlock, no POST and no list refresh occurs. Then a new adjustment from that detail still works.
- Successful adjustment closes its form and original detail exactly once, with the original version/key/body and the normal ResourcePage refresh. Repeat with an unrelated cover arriving before the success: cover route/future/input remain untouched.
- Hold the old adjustment action then cover or close its original detail before invoking it: no new child or request. Close the original detail or revoke the original owner while the form is pending; a late result cannot finish a different/new route or revive old access.
- Keep failures and uncertain-body retry in the form until the user resolves/cancels it; do not equate a normal cancellation, scope rejection or read error with non-null success. Preserve the original identity/date/seconds behavior.
- Independently review and integrate all sibling interfaces before future authorized analysis/type/render/runtime checks. Existing r1 review and historical tests do not prove this new result policy.

## Execution boundary

Only filesystem text/bytes/JSON/hash/difflib and read-only Git/source data were used. No SDK, formatter, analyzer/compiler, tests, AST/parser, candidate function/import, business predicate, process/WinAPI or network was used. Only this new r2 independent report directory was written. Main/Git and both r1/r2 candidate originals were preserved.
