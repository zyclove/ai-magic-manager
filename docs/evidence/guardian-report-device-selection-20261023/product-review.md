# Device selection — independent static product review

Scope: current Main usage report picker, its sole production caller/tests, and the policy/group picker lifecycle and layout patterns. Read only; no SDK, rendered inspection, tests, Git or Main writes. Layout observations below are risks inferred from widget structure, not observed render failures.

## Confirmed P2: stale content and permission-gated cancel

`usage_report_device_picker.dart:38–39` only sets `invalidated`; build59–135 continues showing the old targets, selected count and apparently enabled controls. `finish:48–54` checks `current` before distinguishing a value from cancellation, so its Cancel callback becomes ineffective after revocation. Confirm is blocked internally: this review does not claim it returns unauthorized data.

The actual caller `usage_reports_view.dart:262–287` captures generation and an exact OwnedDialogRoute identity/availability, then checks current/generation again before accepting a result. Repository loss, lifecycle change and disposal schedule that specific route's null completion through131–137. Therefore this is not a claim that every production revocation leaves a permanently trapped dialog. The component still has the defect when its access becomes false without that owner cleanup; revision changes such as loadOptions also cannot rely on access notifications alone.

## Smallest safe behavior change

1. Latch observed revocation synchronously and retain it through an ABA or widget update; immediately render a neutral “工作空间或权限已变化” view instead of names/IDs/counts. Clear the component's selected/search private state. Do not reset the latch when changing listeners.
2. Separate cancel(null) from confirm(non-null). Cancel requires only a still-owned available route; OwnedDialogRoute.finish(null) must remove that exact route even when covered. An ordinary route may only use its own active/current public pop. Confirm additionally requires current access, its own active/current/available route, nonempty selection and the original upper bound. Latch closing before finishing, so held callbacks during reverse cannot return a selection.
3. Migrate old/new accessChanges listeners in didUpdateWidget, then observe current validity immediately. If an old access closure has already lost its captured journey, changing listeners must not restore it. Recheck the returned selected IDs against allowed targets; leave the caller's generation/route/result checks intact.
4. Keep ownership and lifecycle checks local; no global Navigator pop, no new endpoint, timer, state framework or permission policy.

## Minimal interaction polish

- Keep existing bulk action text and limit semantics: union with hidden selection; never silently take the first N. Add visible result count, a clear-search control and the existing policy picker's “只看已选” pattern. Explain an empty selected-only result and offer switching the chip off; clearing search must preserve selection. Disabled bulk should explain that existing selections plus newly matched devices exceed the cap.
- Make clear-all visibly apply to all selections even under a filter; do not secretly clear just the visible subset. A count of hidden selected devices helps review 200 targets without repeatedly changing filters.
- Replace hard substring(0,8) with a safe short-ID formatter. Existing production loads validate targets, but a reusable picker should not throw on a short display ID.
- AlertDialog.scrollable is suitable only if the fixed-height Column/Expanded is also changed. Keeping the old minimum180 content height and its Expanded does not cure header overflow at large text. Use scrollable title/content with a separately bounded lazy list and no forced inner minimum; keep actions outside the body scroll. Do not add a new scrolling framework.

## Comparison boundaries

Policy picker already has sticky closing/generation loss, synchronous clearing before deferred owned removal, and a permission-independent cancel501–508. It includes clear search/selected-only/local-page guidance, scrollable content and narrow390px/text2x test source. Preserve its50-target, group-version and preview/publication contract. Its narrow test237–256 checks no exception and non-null action but does not actually tap the final action; do not overstate it as runtime proof.

Group batch picker39–87 has sticky revoked access and current-route confirmation. Its revoked build hides private rows and offers a separate close; DeviceGroupsPage.present91–136 also guards and closes the exact route and filters results. Its original Cancel is current-gated, but this is not the same stale-content defect as usage. Keep this round focused on usage. Group selection is paged, capped50 and rechecked by the existing registration/group-version batch API. Header-plus-Expanded can still be tight in a short, scaled viewport; no render failure has been demonstrated. No dedicated DeviceGroupBatchPicker Main test was found; the generic direct-submit suite only references DeviceGroupsPage.

## Required followup test source, all UNRUN

Retain both existing200-limit cases. Add explicit owned-route cases for initial denial; access false→true before a pump; no-pump held Confirm after cancel; current and covered Cancel completing null without removing the cover; old callbacks after dispose; listener migration. Exercise hidden selections plus filtered union at/above cap, selected-only empty state and clearing search. Use a real dialog host and preserve the caller Future; do not only embed the picker in Scaffold or only assert after disposal. At320px/short viewport/text2x, explicitly scroll and tap Cancel/Confirm rather than merely checking a non-null callback. Keep the existing covered-owner-disposal reports case; it does not cover the standalone invalidated Cancel gap. Runtime verification remains deferred.
