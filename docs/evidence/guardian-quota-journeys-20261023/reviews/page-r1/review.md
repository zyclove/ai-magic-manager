# Independent static review: daily quota page, host key and ViewLifetime

Conclusion: STATIC_NO_BLOCKER for the exact submitted QuotaPage/console-host/ViewLifetime artifacts and their declared coordinated interface contract. All application scenarios remain UNRUN; rendering is NOT_OBSERVED. This does not independently accept QuotaPlansPage (this reviewer authored it), QuotaPlanEditor, ResourcePage.canInteract or an assembled six-file bundle. Those siblings need their separate reviews and coordinated integration.

## Bound artifacts and actual checks

Observed baseline: `bb93c0b0bacfea622e50828e635aa61d738f342b`.

- Page after: 16617B, SHA256 `79c1ef564769dce7dd2562aace02c4bf08255d72ab11e3996455e3299acb74f8`.
- Host after: 87508B, SHA256 `0b1ee926b5f73f4c79862778dc831953ae82bf4858136a458bdaf1891bdc30a7`.
- Combined full patch: 31864B, SHA256 `04408b5204f191f944f9beec1afa5f83e03bef0fbc101314b99f711920a659d1`.
- Page pins: 3079B, SHA256 `c252a12055b747dee7ae520aa71710f793f4594eac661b34cd1c0631e1409edb`; delivery.json 1148B, SHA256 `6b3eb8dbdb3c56fec2d0149bce4bdb5c87750b875d6f18e87fd6970c185de7e8`.
- New helper after: 1068B, SHA256 `c68c7457f2cd212df0b8d34b727c8e07364b6605832c41dc133d70355d719815`.
- Helper pins: 2029B, SHA256 `cdd68ef44ac7483fc4bb3a1bc6295772f58244b272eb039779bf4c05b0ae08a3`; delivery.json 693B, SHA256 `3782aafe93430f9b9758f7bb8866441f0b3e4273b2e5dc364c959d22fae8c332`.

Own byte readbacks `338b90` and `d6a4bc` naturally exited 0. The complete combined patch reconstructed exactly from the two raw before/after pairs; helper /dev/null patch reconstructed exactly. Both raw before files match Main. New helper path is absent from Main at this checkpoint, as its manifest claims. All pins/files and delivery descriptors matched, including the six baseline dependencies in both bundles (twelve occurrences, six unique paths). Exact candidate memberships matched: page eight files, helper five files. Author metadata was read after it was actually sealed; it was not prefilled from intended results. Input-pins.json binds twenty-two unique paths read for this review.

Host after differs from host before by exactly the one QuotaPage construction at console_pages.dart:287-289: the added key tuple is Session identity, actor, tenant, role and scopeGeneration. A literal full-file comparison confirmed no other host changes.

## Page owner and original parent bindings

- QuotaPage initState captures the original Session/root, constructs DeviceSubflowScope, and merges it with own ViewLifetime changes (after.dart:26-50). permitted checks mounted, active lifetime, same widget Session, same root and quota permission; DeviceSubflowScope also fixes actor/tenant/role/generation and authenticates its own Api.
- Host key replacement and State.didUpdateWidget cover new identity instances; deactivate invalidates synchronously before inherited lifetime presentation is delayed. dispose invalidates/releases the lifetime then disposes the Session scope. The current predicate reads lifetime.active before scope.current, so held callbacks reject immediately even when an old dialog remains mounted until a later frame.
- The page AnimatedBuilder replaces stale contents. The daily ResourcePage uses pageScope.api and current for owner/read validity, with interactive(context) supplied through the declared separate canInteract hook. The plans child receives the original stable current/changes pair. No fresh Session scope is captured merely to bless a stale form submission.
- interactive checks owner validity plus the actual initiating context's active/current route and, for an OwnedDialogRoute, available. This top-route condition is not part of persistent read/accepted-response predicates.

## Create and adjust: genuine ancestor binding before awaits

Daily create after.dart:157-236 and adjust:285-330 both start with current initiating route/root/write checks. They allocate DialogAccessBinding from that real launching context before async work, then allocate a journey DeviceSubflowScope whose permitted predicate includes the page current, binding.permitted and original root/write permission. This binding matters for adjust: its launching context is now the owned detail route, so binding checks parent OwnedDialogRoute.available even before the parent's popped signal is published.

Create subject/application preflight uses scoped Api and rechecks current/top route after each await before presenting a form. Both forms merge page/own-scope/binding changes and expose scope.current to the existing shared formDialog. Their write callbacks use that same captured scope.api; requestId, If-Match pool version, endpoint, target fields, local date/zone and minute/second validation/conversion remain the original business values. The new guard does not recapture owner or change a retry's body/key/version.

For an already-admitted valid write, scope validity does not require the parent isCurrent. A form legitimately covers its original detail/page, and a later unrelated cover does not invalidate the writer. Shared formDialog checks its persistent parent/hasAccess, then shared EditDialog completes its own Owned route even when covered. Thus the candidate does not swallow a valid accepted completion by adding a post-await top-route condition. Parent/window access loss still rejects a new dispatch or late delivery through the scoped Api. No claim is made that already-sent network effects can be undone.

## Details, adjustment return and ledger coverage

Details after.dart:238-282 binds before its GET, scopes that request and rechecks before opening scopedDetailsDialog. Existing period, balance, reservation/execution caveats remain. Shared details actions check their current own route before invoking the action; adjust/ledger additionally call interactive on the actual detail context at their own entry.

Ledger is now a retained child of details (closeOnSuccess:false). It captures a DialogAccessBinding to that original detail before presentation; accepted requires that binding plus its own available/active route. Therefore an external finish of a covered original detail invalidates the ledger immediately on the next predicate read, while ordinary coverage by a legitimate child does not revoke either owner. The merged changes drive access-loss concealment; the scoped ResourcePage checks the same accepted predicate for reads. The separate canInteract=route.isCurrent rejects held covered refresh/search/clear/append events when the sibling hook is integrated. Its reauth also checks accepted/current. Close requires only own route available/current and calls finish, so a revoked redacted ledger can close without old write permission and cannot pop an unrelated cover.

Returning from the ledger leaves the original details available. Adjustment uses the shared details action's default closeOnSuccess:true. adjust currently returns void and discards formDialog's result: after either successful save OR normal user cancellation, the detail action returns normally and closes the details. This matches the original eventual return-to-list flow, whose details were closed before opening adjust. It must not be described as cancel-adjust-returning-to-details; no such distinction is implemented. No new cancellation-return defect is asserted for this scoped patch, but this actual UX behavior belongs in later checks.

## ViewLifetime: immediate loss, deferred publication and release

The full helper was inspected. invalidate returns after the first call, sets active=false synchronously and schedules the notifier value=false publication. dispose is idempotent, calls invalidate and only then queues notifier disposal. If both occur in one turn, FIFO post-frame callbacks publish loss before setting disposed and releasing the notifier. Because dispose does not set disposed early, it cannot suppress its own prior loss notification. Both paths request a visual update.

Callers use active for immediate access decisions and changes for redraw. The helper has no reactivation path. Existing DialogAccessBinding checks its access predicate synchronously on construction, so a later child constructed against an already-lost lifetime fails even if its notification frame has passed. Page scope disposal alone would not notify surviving root dialogs; this independent lifetime signal supplies that missing presentation path. Actual Flutter callback/teardown timing remains UNRUN; no physical real-time guarantee is claimed.

## Newline and review boundary notes

QuotaPage before is 13956B with 303 CRLF lines. Its after is 16617B with 380 LF lines and no CRLF. The full mixed-newline patch therefore displays a whole-file replacement; this normalization is real and was not hidden by the reconstruction. Both host versions are LF and only the advertised key tuple changed. Root explicitly retained these reviewed original bytes after this observation. This is nonblocking source churn, not a claim of newline preservation.

The draft's first inventory/reading attempts guessed quota-page.patch and later delivery-pins.json, which did not exist. The actual inventoried paths are quota-page-scope.patch and delivery.json. The failures opened no alternate source and did not alter the artifacts. Final checks used the actual sealed metadata and actual members above.

No application/Flutter analysis or runtime test was run. Existing shared-dialog tests are not substitutes for an actual quota host navigation test. The Editor candidate was announced by its author during this review but was not inspected or accepted here. ResourcePage.canInteract and the full sibling integration are separate review prerequisites; this report does not turn a pending signature into a compiled contract.

## Required later scenarios, all UNRUN

- Current daily create and adjust preserve request/body/key/version, original uncertainty retry and normal completion. New request entry while covered is inert; already-sent legitimate write completed under a cover finishes only its own form/detail and preserves the cover.
- Lose page/Session/role/tenant/generation while lookup, form or detail GET is pending; before any pump held callbacks reject and later content is concealed. Original ancestor Owned close rejects descendants immediately; access cannot revive by a return-to-same-owner snapshot.
- Open ledger from details; cover it; accept an already-sent read while keeping the cover. Reject covered refresh/append/search/clear, allow them again once current, and make old close inert after completion/dispose. Externally close the original detail under ledger/cover and confirm redaction without popping the cover.
- Check real cancellation policy: normal adjust cancel returns to list; ledger return keeps details. No duplicate refresh/submission after either result. Verify quota information and safe closes on narrow/large-text layouts rather than inferring rendered success from source.
- Apply all six coordinated siblings only after their independent reviews, then perform future authorized analysis/type/runtime checks. This static no-blocker conclusion covers only the exact page/host/helper bytes pinned here.

## Final scope

No blocking static finding in the reviewed page/host/helper implementation. No implementation changes requested. Only this new independent cache report was written; Main/Git/candidate originals and historical evidence were preserved.
