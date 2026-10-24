# Schedule retry test typed-finder correction

Changed only apps/guardian/test/editor_submit_guard_test.dart. Before21431/SHAa8d24bca8147a38ffe0c5db9b620e533e47b18cf371c9198dc62d9ab33280ed9; after21581/SHA0e0a0d3f2392bddf6f94f6cbc42dcc93bfcc9b2d3f2fb1aeef8c3044b03fb99b. The before/after raw snapshots and minimal unified patch are preserved here. No SDK, browser, Dart analyzer/formatter/compiler, fixture or Git write was performed for this fix. Retest is UNRUN.

## Actual failure and source cause

R4's original reporter log contains all13 visible completions:10 success and3 error, plus terminal done. The network/server/unexpected variants in the shared loop all recorded `Tooltip is not a subtype of IconButton`, at the same generated editor_submit_guard_test.dart.js811:46 site. Their error events are framework TypeErrors, not evidence of a failed production business assertion. The original actual log is pinned and not rewritten; the summary here preserves the failed names and exception prefixes.

Before the patch, source382–385 passed `find.byTooltip(...).first` into `tester.widget<IconButton>` to capture two remove callbacks. The pinned Flutter finders.dart:362–376 documents and implements byTooltip as a predicate matching Tooltip widgets. controller.dart:799–801 obtains the matching widget and directly casts it to the requested generic type. IconButton.build in material/icon_button.dart:703–717 (Material3) constructs a nested Tooltip around its icon; the Material2 branch764–768 likewise constructs a Tooltip inside the IconButton's build subtree. A matching Tooltip is therefore not the parent IconButton widget.

All three loop variants reach the first incorrect capture before save() and before their simulated network/server/unexpected failure is injected. The second removeException capture uses the same invalid lookup pattern and needs the same correction even though the first cast prevented reaching it in these actual failures.

## Minimal change and preserved behavior

Only the two callback-capture finders were changed to the standard find.byWidgetPredicate selecting `widget is IconButton && widget.tooltip == originalText`, retaining .first and .onPressed!. The exact original tooltip strings are used for the weekly-window and exception remove buttons. This obtains the public IconButton directly without assuming that its Tooltip wrapper is itself a button or relying on internal M2/M3 wrapper layout.

There is no added helper, delay, exception swallowing, skip, deleted assertion, selector change or application change. The .first semantics still select the first window button and the existing exception button. Captured callbacks still exercise the same stale-callback behavior after the pending/unknown transition.

Static byte verification8d8bf5 natural0 proves the complete after file equals the complete before file with exactly one four-line→six-line replacement block; all bytes outside that block are unchanged. Both versions contain10 testWidgets declarations, the same parameterized loops expanding to13 visible cases, and71 expect calls. In particular, tooltip-count, locked-field/pop, original body/idempotency-key, duplicate-submit, close and stale callback assertions remain intact. Production editors.dart is unchanged52075/SHA208926fbdc201d66fc5bf3e261465d9d76488141c27ed1b30bcbf40a4d0ff957.

## Remaining verification

Re-freeze/bind the modified test bytes before the next execution. The immediate meaningful rerun is the three exact affected retry cases (network/server/unexpected), retaining their complete existing assertions and the normal deadlines/ownership/force rules. The unrelated10 prior successful cases are not newly claimed to have executed on this changed test file; no broad rerun was performed by this agent. Full13 inventory remains present.

R4 remains RED. Its worker forcedTermination flag and sticky observer identity failures are separate open evidence handled by the source agent; this finder correction does not waive or explain them and does not establish acceptance of the overall run. Root will determine the next fixed validation plan and commit after verifying it.

Read evidence:2cd208/00fdcb/e2d2d1/c119ab/634a86 naturally exited0; backup867794 and static delta8d8bf5 naturally exited0. Only this one main test file and this task-owned evidence directory were changed. No Git operation or production modification was made.
