# Workbench/shared forms: existing regression intake

Static coverage review only; these31 existing cases have not run in this task. Guardian static-analysis success does not imply their runtime acceptance. No tests or production code were added/changed.

## First existing batches

| File | Static case count | Platform recommendation / explicit metadata |
|---|---:|---|
| workbench_view_test.dart |12 (7table rows+5other cases)|Flutter VM eligible; no TestOn/Tags/skip|
| dialog_submit_guard_test.dart |1|Flutter VM eligible; no TestOn/Tags/skip|
| action_details_route_ownership_test.dart |14|Flutter VM eligible; no TestOn/Tags/skip|
| editor_submit_guard_test.dart |4|Browser required: TestOn('browser') at1; no Tags/skip|

First run the three existing VM files (27cases); next run the browser-only editor file (4cases) in its separately scheduled browser window. These are Flutter widget tests, not plain `dart test` cases. No flags/annotations should be removed to force VM execution. The browser file imports Session directly at9 and editors at10; Session imports dart:html at3. The other three have no browser fixture or unconditional html/io in the necessary repository import chain (design→api/scoped_http_client/owned route/labels and shared usage_reporting models); their existing181inventory classification is platformneutral. External package/runtime availability was not freshly certified here.

## What existing assertions actually cover

- Workbench test52–119: all7next-action priorities and intended callback targets; exact shortcut dedup is asserted. A primary connection-check/view-device action still leaves add-device available; primary add-subject/add-device/policies/reports suppress only that same shortcut. Tests121–174 check organization naming, subject metric/add-subject/add-device targets, unavailable sections/counts/audit hiding. Tests176–201 check loading with null summary and null-summary401 retry+reauth. Tests203–239 check refreshed timestamp and busy controls;241–277 checks390×844/text1.5 urgent/metric tapping and no captured layout exception. This is presentation callback/layout coverage; actual host actions/session/HTTP/navigation are not constructed. The real host routes these callbacks via perform/current at console_pages.dart2180–2205.
- Shared submit guard9–44 captures one save callback twice before a frame and asserts exactly one onSubmit call while a Completer is pending. It does not assert a412 outcome, immutable copyable draft, returned value, or post-success route completion.
- Editor tests136/192/235/275 cover duplicate queued submit for Schedule/Policy/Member/Class. Schedule/Policy assert one POST and exact path/body after blocked client acquisition; Member/Class assert one pending body. Their cleanup explicitly unmounts before releasing responses, so these four do not accept actual editor successful-return behavior.
- Owned-route tests64–184 cover successful action/form completion under a real unrelated covering DialogRoute, completion of the correct caller/result, ordinary success return, and closeOnSuccess=false preserving own window/cover. Tests94/108 cover access loss before a frame and sticky loss/restoration. Tests185–343 cover stale save/cancel/confirmation/details close/dropdown/reauth callbacks after close and frozen uncertain dropdown content. Most close cases pump through disposal before invoking the held callback; they do not prove the immediate close-to-dispose interval. No full backend mutation is exercised.

## High-value gaps after the first actual runs

1. **Old statistics with error/refresh:** production workbench_view.dart123–125,153–161 suppresses summary-derived next action and labels retained data when summary!=null plus error or refreshing. Existing test176 uses summary:null; test203 sets busy:true but not refreshing. No listed case builds old summary+503/NETWORK_ERROR, refreshing:true, then fresh success. Add a later VM view regression for stale notice/retained metrics/no stale next-action, retry/refresh busy state, and restoration with the new timestamp/target. The actual host HTTP/generation recovery remains a separate browser integration concern.
2. **Shared HTTP412 draft and stale version lock:** design.dart359–367,459–489,520–534,612–629 retains an unmodifiable attempted snapshot, maps dropdown codes to labels, shows selectable draft, removes submit, and rejects a held old save via versionConflict. None of the four files sends412 or asserts that branch. A later focused VM test should cover text/numeric/dropdown draft labels, no second onSubmit from a held save, closed form result, and no wrong-route pop. class_action_dialog_test.dart73–91 already tests its different ClassActionDialog412 disabling/refresh result; that does not cover shared EditDialog draft UI or caller If-Match/version behavior.
3. **Real entry/cancel return:** generic owned-route behavior is covered, but Workbench callbacks are counters and editor cleanup unmounts. The current Subject/Class common-entry forms/defaults, cancellation preserving originating business detail, explicit refresh/reopen after412, actual request key/If-Match and latest-version resubmission are not asserted by this selected set. Reuse the existing production host/browser fixture only after the first actual results show the remaining gap; do not count generic route success as this journey acceptance.

All gaps are coverage observations, not newly demonstrated product bugs. No SDK/AST/test/formatter/browser/network/process API or candidate function was run; only this new cache note/pins was written. Full181 scope remains required; this31case selection does not replace it.
