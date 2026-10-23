# Independent QuotaPage r3 delta and full-patch review

Conclusion: STATIC_NO_BLOCKER for the exact RootPage r3 listener refinement and retained r2 page/host behavior. All application scenarios are UNRUN and rendering is NOT_OBSERVED. This does not independently accept the self-authored Plans candidate, Editor, ResourcePage.canInteract or the assembled six-source runtime. No source was changed by this reviewer.

## Fixed artifacts and actual checks

Baseline remains `bb93c0b0bacfea622e50828e635aa61d738f342b`.

- after.dart: 16855B, SHA256 `df01196e5c457562481df52aed2585597fc3422a6c8821d166565e3cae243063`.
- Host after remains 87508B, SHA256 `0b1ee926b5f73f4c79862778dc831953ae82bf4858136a458bdaf1891bdc30a7`.
- Full combined patch: 32108B, SHA256 `b92479c6da26c072e786016d70a63cbe87a690b7fc7a7bd029747800212eec37`.
- pins.json: 3158B, SHA256 `0b087bb9892c8d3c181fc5407d247ab1baf1cd51eaf3056ad5726e4b4d8a7b32`.
- delivery.json: 1148B, SHA256 `c9723ddae98b3739c2f172fd5ce374de6e97f6c35fa33b1da0af8827e692b177`.

Own metadata/text readback f848e0 naturally exited 0: four declared identities, six source/evidence pins, seven delivery descriptors, all six baseline dependencies and exact eight members matched. Both Main raw before images match. The entire combined two-path patch reconstructed byte-for-byte. The r2 before, host-before, host-after and baseline dependency metadata are unchanged. A literal full-file construction confirms precisely four listener expressions differ between r2/r3; no remaining after-source byte differs.

The prior independent r2 report remains 7753B/SHA `011e9a52a108db3eb96eb0471a52647933b0d359c3a44e9d5907a7b396f7e979`; its original input pins were reread and matched. r1/r2 candidates and reports remain historical originals. Whole-file pins bind exact originals; dependency reasoning is scoped to the relevant helper/functions already reviewed. No Dart AST/parser, candidate function, compiler or business predicate was executed by this text comparison.

## Exact delta

1. Daily create form accessChanges: merge([changes, scope, access.changes]) -> access.changes.
2. Daily adjust form accessChanges: the same merge -> access.changes.
3. scoped daily details accessChanges: merge([changes, access.changes]) -> access.changes.
4. Owned ledger AnimatedBuilder.animation: the same merge -> access.changes.

The page's own stable changes merge and every current/interactive/accepted predicate remain unchanged. Endpoint/body, original key/version, date/minute validation, uncertain retry, cancellation result handling, safe owned close, scoped API and host constructor/key are all byte-identical to r2. This is listener ownership cleanup, not a new workflow or backend contract.

## Why the local notification remains sufficient

Each of these four flows already constructs its local DialogAccessBinding against the original page `changes` BEFORE asynchronous work or presentation. That binding subscribes once and reads the original current/ancestor predicate synchronously. It owns an independent notifier and retains it until the awaited route/action Future ends, then disposes it in the existing finally.

Thus removing the direct raw page/scope/lifetime merge from the route UI does not remove the binding's parent observation. Session/role/tenant/generation or page lifetime loss is still read immediately by scope/current/permitted before dispatch and publishes concealment through the local binding's own changes. For adjust and ledger, the binding still captures the true Owned detail parent and checks its available state; coverage alone remains valid. The additional journey scope in create/adjust does not introduce an independent lifetime that should outlive or replace that page/ancestor binding: it is captured from the same valid owner and released only when its form flow ends.

When a page is deactivated or disposed, its synchronous ViewLifetime.active becomes false before any deferred notification. A held callback therefore rejects immediately. The page's delayed signal reaches the binding, which schedules its own presentation notification. Surviving route UI listens only to that route-local notifier and can rebuild/redact without directly adding listeners again to an already-disposed pageScope/ViewLifetime notifier. The local binding remains alive until its route Future/finally, aligning notification ownership with the UI that consumes it. Actual Flutter teardown/media timing remains UNRUN, not a reproduced failure or universal listener guarantee.

## Retained route/result behavior

- Daily create/adjust preflight, original scope and real parent DialogAccessBinding remain unchanged. Passive in-flight valid reads and accepted write completion do not gain a top-route condition.
- r2 cancellation policy remains: adjust returns the real form Json?; null keeps the same details, while non-null success with original access and available captured detail finishes only that Owned route. The post-await branch still does not require isCurrent, preserving a valid unrelated cover.
- Ledger owner/read validity still uses parent binding plus its own active/available route; canInteract remains a separate current-route user-event check. Access-revoked safe close still needs only own availability/currentness, not old permission. Returning from ledger still keeps details.
- Original QuotaPage CRLF-to-LF normalization remains disclosed. Host bytes and its sole Session/actor/tenant/role/generation key change are identical to r2. This delta does not claim newline preservation or additional host changes.

## Required later scenarios, all UNRUN

- Retain create/adjust/details/ledger under a cover, end the original page, then force an actual media/dialog rebuild after its page notifiers are disposed. Old private fields stay concealed, no disposed-notifier addListener error, and route safe close remains usable.
- Before the first pump after owner or ancestor loss, held event/API callbacks remain inert. Later notification/GET/write results do not revive the lost owner; same-workspace away-back or generation-only changes remain sticky.
- Current forms and details remain usable. Valid covered reads/save success keep the cover; cancellation keeps the same detail; successful adjustment closes its own original detail and lets ResourcePage perform its necessary internal refresh.
- Verify binding/listener release at the real owned route's Future completion and late coverage/disposal sequences. Preserve key/version/body and original uncertainty behavior.
- Independently review/integrate all six siblings before future authorized type, analysis, rendering and runtime checks. No existing pass or earlier static report is presented as execution of this r3.

## Execution and delivery boundary

Only filesystem text/bytes/JSON/hash/difflib and read-only Git/source data were used. No SDK, formatter/compiler/analyzer, test, AST/parser, candidate module/function, business predicate, process/WinAPI or network was used. Only this new independent r3 directory was written. Main/Git, Root candidates, helper and prior reports remain unchanged. There is no blocking static finding in this narrowly reviewed refinement.
