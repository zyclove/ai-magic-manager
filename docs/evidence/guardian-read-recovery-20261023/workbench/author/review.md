# Workbench common actions r2: static author candidate

Baseline: `7cf2b2b9960db98f90a7f7630ae967e3ea99eba8`. Only `apps/guardian/lib/ui/workbench_view.dart` is proposed. Main and the earlier r1 checkpoint are unchanged; r2 is the final selection.

## Minimal behavior change

Original build 123–125 only computes common actions after summary exists, then 147–172 renders them only in the success branch. A first load or summary/read failure therefore hides independent permission-derived shortcuts.

Common actions are now computed and rendered independently of summary/loading/error. Their existing permissions, optional-callback filters, busy disabling and callbacks are byte-identical. Data-driven `_nextAction` is not generated during error or refresh, so old counts cannot produce a recommendation or suppress a common shortcut through deduplication. Successful idle layout and deduplication stay unchanged.

A failed first read keeps the existing failure panel and shows permitted common actions without inventing counts. With an already-loaded summary, failure/refresh retains its metrics and recent activity, explicitly marked `以下为上次成功读取的数据，当前状态尚未更新。` before the data. The original last-read timestamp remains visible; this view never changes it. Refresh failure uses the Notice warning style. No summary means no metrics/activity/next-action or fabricated zeros.

The header keeps its busy/refreshing disabled state. FailureView receives neither retry nor reauth while busy or refreshing. Parent request/scope guards remain unchanged. Common operations stay usable during a summary read, with actionBusy still disabling them through the existing busy property.

## Same-owner data and source boundary

Dashboard `console_pages.dart` 1988–1994 ties current to the captured scope/session/activity. Scope loss clears data/error/time synchronously at 2012–2028; `_captureScope` binds the original root/session at 2038–2058. The read at 2062–2102 only accepts success/error for current scope and generation; only success replaces data/time. Thus retained summary and timestamp have the current accepted owner, not a recaptured workspace. Existing `perform`/`open` invocation guards at 2105–2143 and callbacks at 2171–2206 are untouched. Original scope/permission checks still run at button invocation.

All source outside build is byte-identical, including fields/constructor/imports, `_open`, `_nextAction`, metrics, common-action permission/callback code and recent activity. No ConsoleActions/Dashboard/shared component/API/dependency change is proposed.

## Read-only coverage and limits

Existing `workbench_view_test.dart` 176–201 covers missing ready counts/connection claims for null summary, but no add callbacks or shortcut visibility assertions. Existing 203–239 covers busy forms/timestamp; other cases cover targets, permission hiding, primary deduplication and narrow text. No test is changed or added. The code review does not demonstrate those tests passing.

All scenarios remain UNRUN: initial loading/failure with allowed and denied shortcuts; retained-summary refresh failure and unchanged timestamp; refreshing suppression of recommendations plus stale-data notice; busy retry/reauth suppression; duplicate and held/stale callbacks under the original host guards; scope loss; successful idle deduplication; narrow/large-text layout. No rendering, SDK/tests/formatter/AST/parser/candidate-function/predicate/process query/network or package install. No Main/Git/shared-cache writes. Author candidate only; independent review and later application validation are still required.
