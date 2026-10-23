# Subject dialog r2: mechanical null-guard delta

Author follow-up to the frozen r1 candidate. Main and r1 are unchanged.

- `_subjectForm` now returns early for `parentRoute == null`, followed by explicit `!parentRoute.isCurrent` / `!parentRoute.isActive` checks and the existing owned-route availability check.
- The captured permission closure reads `parentRoute.isActive`, removing the non-null assertion. No other source bytes differ from r1.
- This is a static clarity change requested after independent r1 review. It does not claim that a Dart warning was observed or that analysis passed.

`console-after.dart` is the complete new console candidate. `r2-vs-r1.patch` is its complete minimal delta. Reuse the r1 `console-before.dart`, `design-before.dart`, `design-after.dart`, and original full patch/review; design remains exactly the r1 candidate. Apply the new console candidate together with the unchanged r1 design candidate.

All cancellation/result/ownership/request-body/version/key/lifetime behavior and public callers remain exactly r1. The change is confined to the initial guard and removal of one `!` within `_subjectForm`; inverse textual replacement recovers the pinned r1 bytes exactly.

No Main/Git/r10/SDK/shared-cache changes. No tests added or run, no UI rendering, no SDK/formatter/AST/candidate function/predicate/process/network execution. Every application scenario remains UNRUN. This is an author delta, not an independent review.
