# QuotaPlansPage r2: route-local access notifications

Status: STATIC_CANDIDATE_UNRUN_REQUIRES_COORDINATED_INTEGRATION. This is an author-delivered delta, not an independent review. Root requested this narrow cleanup before application; the separate classification reviewer will inspect the actual final r2 bytes. Main/Git and r1 artifacts were not changed. No SDK, formatter/compiler/analyzer, tests, AST/parser, candidate function/import, business predicate, process/WinAPI or network was run.

## Fixed artifacts

Baseline remains `bb93c0b0bacfea622e50828e635aa61d738f342b`.

- before.dart is the original Main baseline: 12090B, SHA256 `3635e1a03eab26f663c4dc2d404abd61a84b6f546e2754f5a8450e20ef635d6a`.
- r1 after remains 16238B, SHA256 `621d3f71141ef30904fa70334f4f2f221debd9cff960798ee49e0eedba193fdd`.
- r2 after.dart is 16151B, SHA256 `9abbb08efcb075ba451190ba0dcc678c5682018f18611a1eade65b1f651b5191`.
- Complete Main-before -> r2-after patch is 24570B, SHA256 `5275a4b6e4a4549a564a3dbce97cffd0da6fd7d8a2a74bcaee9c8a82d791ea6f`.

The complete patch is for one production path only, apps/guardian/lib/pages/quota_plans_page.dart. It is not merely a three-line patch to apply against already-modified Main. The selected r1 prior bytes are pinned for exact delta review, and its original six files remain preserved.

## Exact r1 -> r2 source delta

Only these three final local assignments change:

- edit: `editorChanges = Listenable.merge([changes, access.changes])` becomes `editorChanges = access.changes`.
- details: `detailChanges = Listenable.merge([changes, access.changes])` becomes `detailChanges = access.changes`.
- history: `historyChanges = Listenable.merge([changes, access.changes])` becomes `historyChanges = access.changes`.

Every other production-source byte is the same as r1. The full delta was read as text and an exact literal transformation was used to construct it; no Dart syntax or predicate was evaluated. The page's stable original `changes = Listenable.merge([scope, lifetime.changes, parentChanges])` is deliberately unchanged.

## Purpose and lifetime contract

Each flow already constructs its DialogAccessBinding before awaits, subscribes it once to the original stable page changes, and retains it until the route/action Future ends; the existing finally then disposes that binding. Its synchronous permitted predicate still reads the original page/owner lifetime, parent route availability and scope. These checks and all accepted/interactive predicates are unchanged by r2.

The independent root dialog UI now listens only to that flow's own access.changes notifier. It no longer directly adds itself to the page scope/lifetime merge when a retained root dialog rebuilds after the original page has disposed. Parent loss still reaches the binding through its initial stable subscription and its sticky synchronous guard; the binding publishes the loss for presentation through the existing deferred access notification. The route-local notifier lives until its own flow Future/finally, so UI teardown is aligned with the window it represents.

This does not add a new notification framework or a new authorization path. Valid covered completion still uses own route available/active without a top-route requirement; user actions still use route currentness separately. Page labels/list, scope Api, editor calendar/preflight/fixed version/key/body, detail weekday/override content, nested history and owned close behavior are unchanged. No payload, endpoint, permission or existing uncertain-body retry semantics change.

## Coordinated sibling status

The declared interfaces are unchanged: QuotaPlansPage requires original parentCurrent/accessChanges; QuotaPlanEditor accepts optional accessChanges/hasAccess and owns its interaction/completion; ResourcePage separates optional canInteract from persistent isCurrent; ViewLifetime provides immediate active invalidation and deferred changes/dispose. Root is preparing Page r3 with the same route-local notification principle. These other source files are not applied or independently accepted by this author delivery. r2 baseline dependency pins are provenance only; intentional sibling changes require the actual integrated source to be bound again before future validation.

The existing helper input is 1068B/c68c7457f2cd212df0b8d34b727c8e07364b6605832c41dc133d70355d719815. No unobserved sibling hash or runtime result is manufactured. The r1 author review's earlier pending-sibling checkpoint remains unchanged as history.

## Required future checks, all UNRUN

- Dispose/deactivate the original plans page while editor, detail or history is retained under a cover; trigger an actual media rebuild after page notifier disposal. Its UI must stay safe, remain redacted and avoid re-subscribing to disposed page notifiers.
- Before any pump, original page/Session/actor/role/generation loss must still reject held callbacks and network dispatch through the unchanged synchronous predicates; a delayed label/calendar/revision response cannot restore old data.
- Current editor and nested history interactions stay usable. Covered valid reads/save completion remain accepted only for their original lifetime and finish only their own routes; normal close and safe revoked close remain correct.
- Verify listener release after each route future completes, repeated loss notification/disposal, and required internal list refresh. Keep existing key/version/seconds/calendar/uncertain retry tests and add real production-host lifetime cases in a later authorized window.

All application scenarios, rendering, type checking and full six-source integration remain UNRUN. This directory is a complete author candidate artifact set, not a runnable execution bundle, accepted implementation or a goal-complete claim.
