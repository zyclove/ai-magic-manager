# Guardian Quota workflow static audit, r1

Status: STATIC_REVIEW_WITH_TWO_P2_FINDINGS. Every proposed scenario is UNRUN; rendering is NOT_OBSERVED. No implementation or test source was prepared. This is an independent application-source review of the Root intake concern, not a runtime reproduction, backend audit, or authorization-bypass finding.

## Bound source and review method

- Initial and final observed HEAD: `ad9f967a802e0d57dcea0e5289bf76d4e55070af` (`f01386`, `54007c`). The narrow read-only Git diff of fourteen reviewed production/test dependencies against that commit was empty at the final checkpoint.
- Intake `.cache/guardian-quota-followup-source-note-20261023.json` is an unverified concern; it is pinned as provenance and was not treated as proof.
- Complete QuotaPlansPage/QuotaPlanEditor/QuotaPage text was inspected, with targeted reads for host routing, Session, Api, shared dialogs and the five existing editor test cases. All original files are pinned in `input-pins.json`; whole-file pins do not imply a general audit of every dependency function.
- Only new files in this audit directory were written. No SDK/test/formatter/analyzer/compiler, AST/parser, candidate module/function, business-predicate simulation, process/WinAPI, network, Main or Git writes were used.

## QUOTA-R1-01 — P2: repeat-plan journeys are not bound to the originating page and access lifetime

### Production data flow

1. `apps/guardian/lib/main.dart:60-68` and `ui/shell.dart:92` watch the mutable Session. Shell body keys are tenant/section only (`shell.dart:221-226`). `ConsolePages` checks canOpen at build (`console_pages.dart:194-198`) and returns QuotaPage directly (`:286-287`). The nearby resourceCurrent closure is only passed by the general resource factory; the QuotaPage branch bypasses that factory.
2. `pages/quota_page.dart:45-52` keys plans/list by root only and hands the same Session to QuotaPlansPage. No actor/role/scopeGeneration page capture or listener is installed there or in QuotaPlansPage. Same-root role/generation changes therefore do not create an immutable quota owner; replacing a body on a different root does not bind already-pushed root dialogs to the disposed body.
3. `quota_plans_page.dart:104-138` captures root/key/version but uses live `session.api` for children/app lookups and the POST/PUT. The checks after lookups only test the original context.mounted. The showDialog builder supplies no accessChanges/hasAccess/owned route to QuotaPlanEditor. Its onSubmit closure has no parent-page/route/actor/role/generation guard at dispatch or completion.
4. Calendar reads use that same live Api and captured root (`quota_plans_page.dart:59-63,127`). Editor.loadCalendar gates only on its own mounted and calendarGeneration (`quota_plan_editor.dart:76-94`). That generation prevents a previous subject read from winning a later subject choice; it does not observe Session ownership changes.
5. Editor.save checks busy, form, calendar and subject, then dispatches the supplied closure (`quota_plan_editor.dart:168-198`). An already-open editor has no Session listener and does not hide or disable its old contents when the parent page/owner changes.
6. Session.api is a long-lived unbound Api (`core/session.dart:29-33`). authenticatedClient returns the current client (`:203-205`). Api.send only enforces an optional/bound scope when one is supplied (`core/api.dart:213-251,268-287`); these repeat-plan calls supply neither. Capturing a path and idempotency key does not capture the UI access lifetime.

### Complete host sequence, without pretending a workspace selector can be clicked through a modal

- The real workspace dropdown starts `Session.selectTenant(B)` and awaits membership (`shell.dart:114-145`). selectTenant synchronously increments scopeGeneration and notifies, while tenant A remains assigned until membership returns (`session.dart:310-339`). The dropdown handler does not disable A's quota entry while that asynchronous selection is pending.
- Before B membership resolves, the user can open A's existing repeat-plan create/edit flow and reach its root dialog. The original lookups/form root are A. This sequence starts the workspace change before the modal exists; no through-modal interaction is assumed.
- B membership then resolves. The watched body changes tenant key; the originating A page can be disposed while the pushed editor route has its own mounted State. The dropdown's post-await navigation deliberately checks its original parent route is current (`shell.dart:119-125,132-137`); an opened modal makes it non-current, so there is no unconditional host pop/redirect that supplies the missing form invalidation.
- The visible old editor still invokes its captured A path with live session.api. If the same account remains authorized in A (a normal two-workspace account), the backend can accept that write even though the current workspace is B. Backend authorization need not fail and does not express the user's current UI intent. Same-root generation changes are likewise not observed.

This is a missing UI operation-lifetime check. It is not a claim that the server bypasses tenant authorization, that every actor replacement preserves a dialog, or that browser login/logout navigation never destroys it. Actor/role replacements have the same missing capture in the source, but their complete real authentication-navigation timing has not been reproduced here.

### Other manifestations of the same missing scope, not additional findings

- Repeat-plan list, label reads, details and revisions use session.api with no isCurrent/scope (`quota_plans_page.dart:27-46,67-70,141-145,217-257`). Labels only compare current root, which permits same-root generation/actor changes and an unobserved A-B-A return. Details only check original context mounted before opening and after the dialog future; history ResourcePage is a separate dialog subtree with no isCurrent callback.
- Daily quota read-only details/ledger likewise use unbound session.api and bare dialogs (`quota_page.dart:171-220,263-300`). An already-open details/ledger window does not observe owner loss and can retain old data. The original page-mounted check does correctly reject a new detail continuation after that page is disposed; do not conflate that protection with a listener on an already-open dialog.
- ResourcePage acting/loading and its resourceGeneration guard (`ui/resource_page.dart:92-181`) only cover its own async lifecycle and optional isCurrent. They do not supply absent external scope to a dialog owned by another State. Busy prevents concurrent fresh callbacks; it does not revoke a retained callback or a detached dialog's API closure.

### Existing protection that must be preserved

Daily create AND adjust already capture DeviceSubflowScope before asynchronous work (`quota_page.dart:97-118,155-168,223-260`). Their permitted functions require the originating page/context, Session identity, root and canWrite; DeviceSubflowScope also captures actor, tenant, role and scopeGeneration and listens synchronously (`device_subflow_scope.dart:8-43`). They use scope.api and pass scope/hasAccess to shared formDialog. In particular, a stale daily detail action cannot blindly obtain an unscoped adjust writer: adjust rechecks its own valid write scope before showing or submitting. No duplicate finding is raised for these protected writes.

### Most reasonable existing pattern to reuse

Create one immutable quota page/journey owner before any list/preflight/dialog awaits, using DeviceSubflowScope and page active/dispose identity; key the host by Session/actor/tenant/role/generation and provide isCurrent plus scoped Api to its ResourcePages. Bind every repeat-plan editor/calendar/details/history and daily read-only child to that original owner through the existing DialogAccessBinding/accessChanges pattern. Revoke sticky on page/owner loss, redact old data, and recheck before dispatch and before accepting a late result. A fresh scope captured only when an old form finally submits would incorrectly bless its stale contents. Keep captured endpoint/version/idempotency key and exact uncertain retry body; do not silently retarget them to the new workspace.

### Required later scenarios, all UNRUN

- Real pending A-to-B membership begins before opening A create/edit; complete B while the root editor is open; held/current save, calendar retry and reauth must be inert, old fields hidden, and no A write sent after loss. Close must safely remove only the old dialog. Repeat owner loss during lookup and calendar response.
- Same-root generation-only invalidation (including a real already-in-flight loadTenants -> selectTenant) and a failed/away-back selection must not revive the old editor/read windows. Use actual Session transitions, not a predicate-only substitute.
- Already-open details/revisions/ledger must redact and reject retained refresh/append/open callbacks after original page, role/actor or scope loss; late GET results must not reappear. Cover preservation remains required.
- Current workspace create/edit/calendar, original If-Match/key and exact uncertain retry remain usable. Daily scoped create/adjust protection stays intact.

## QUOTA-R1-02 — P2: repeat-plan editor actions and completion do not own their route

This is independent of QUOTA-R1-01: it occurs with the same valid workspace and actor.

### Evidence and concrete branches

- `quota_plan_editor.dart:168-171` guards save only with busy/form/calendar/subject. It has no mounted/active/current/available or synchronous closed check before dispatch. `:423` cancel directly calls Navigator.pop; production uses an ordinary showDialog (`quota_plans_page.dart:119-138`).
- A valid editor can be cancelled while idle. During its reverse transition the State/Form can still be mounted and calendar populated. Invoking a previously captured save then passes those entry checks and calls the production POST/PUT closure even though the user has closed the form. The parent onSubmit has no completed-dialog guard either.
- For a legitimate in-flight save, `quota_plan_editor.dart:197-198` awaits onSubmit and, if mounted, executes Navigator.pop(context). If an unrelated dialog covers the editor before that response, this pops the current top route (the cover), not necessarily the originating editor; the original editor may remain open. PopScope(canPop: !busy) only constrains popping this editor and does not bind Navigator.pop to a particular route or prevent covers from being pushed.
- A retained cancel callback also has no action-time busy/route/closed check: although the newly built cancel button is disabled while busy, an old callback invokes Navigator.pop directly. The exposed handlers can therefore bypass the build-time disabled state; a busy guard in save alone is insufficient.
- Date picker/override work (`:135-165`) and detail/history/ledger close handlers (`quota_plans_page.dart:197-206,255-258`, `quota_page.dart:201-212,296-299`) use mounted or bare top-route pop, not a shared owned window identity. These are variants to address with the same route-lifetime design, not separately counted defects.

No exact runtime timing or rendering failure is claimed. The close-before-dispose and covered-success branches above are supported by the full production call chain, and match the ownership distinction already implemented elsewhere in this application.

### Most reasonable existing pattern to reuse

Present quota windows through OwnedDialogRoute and keep its available/active/finished state in every interaction guard. Interactions should require the original route is current and access is valid; close must become synchronously terminal before the transition. A valid asynchronous save may finish its own route while covered through OwnedDialogRoute.finish, without popping the cover or requiring that cover to disappear. Bind override children to the same parent lifetime and recheck after each child await. Shared formDialog/EditDialog already demonstrates a scoped form with owned completion (`ui/design.dart:267-309,358-389,449-475`); scopedDetailsDialog plus DialogAccessBinding supplies the existing detail pattern. Reuse these mechanisms instead of creating a new modal framework. Keep an access-revoked safe close independent of write permission.

### Required later scenarios, all UNRUN

- Capture save, cancel the current production editor, then invoke held save before any pump/dispose. Assert no POST/PUT; repeat after dispose and under a later unrelated route. Use a real owned route/future once implemented.
- Begin valid save, add a covering notice, complete save: only the original editor future completes, the cover and its input remain, no duplicate submission; late held cancel/save cannot affect it.
- Retain cancel then begin save; old cancel must not bypass the busy policy. Current cancellation and current successful save still close exactly once; a covered close must not close the cover.
- Invalidate/close the parent during date picker or override form awaits, then return old results; do not reopen a child or mutate the old parent. Keep normal current override editing functional.

## Existing tests and validation limits

`apps/guardian/test/quota_plan_editor_test.dart` has five direct editor tests: target identity copy, error visibility, corrected validation, server-calendar/seven-day seconds payload, and uncertain body retry. Its helper (`:7-30`) supplies fixed maps, an immediate local calendar callback and a caller-supplied onSubmit stub. It does not construct Session, QuotaPage, QuotaPlansPage or the real mutable API host, and it has no cover/closed-before-dispose test. Its existing uncertain retry assertion is valuable and should remain, but cannot prove these owner/route cases. No existing or new test was run, and no old result was promoted to cover this audit.

## Delivery

Exactly two P2 findings, source-scoped. No implementation was authorized by this audit, no tests were changed, and no execution/grant/bundle was created. Input and report pins are separate from all historical source freezes and the pending four-file stage; this audit does not block or modify that stage.
