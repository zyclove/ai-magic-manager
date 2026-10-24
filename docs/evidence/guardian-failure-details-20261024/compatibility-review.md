# Failure details: independent static review and compatibility updates

Conclusion: no new static blocker found in the reviewed four-file scope. This supports committing unrun source; it does not prove compilation, widget behavior, rendering, keyboard operation or full-project acceptance.

## Production and new component tests

- Read the author's complete final patch and all nine new cases. Main design34356/9bbcac70 and test8857/4064e0c2 match its final pins. The design prefix/suffix outside FailureView equal HEAD raw bytes. Retry/reauth eligibility is unchanged:401 or unknown errors may expose the supplied reauth callback;403 does not. Unknown exception text is never converted to user-visible diagnostics.
- Material ExpansionTile has the exact used props in this installed SDK (constructor230–260), defaults initiallyExpanded=false/maintainState=false (238–239), and removes closed children after animation (870–889). Expansion uses ListTile with Semantics/onTapHint and enabled tap (718–735); ListTile delegates to focusable InkWell (855–870), whose Actions recognize ActivateIntent and ButtonActivateIntent (808–809,1313+). These are source facts, not executed accessibility results.
- ExpansionTile initializes from its nearest PageStorage bucket (590) and writes state there (627); PageStorage identifiers use ancestor PageStorageKeys (page_storage70–123). Final local PageStorage isolates outer scroll/page storage. Its fault record ValueKey changes only for code/correlation changes. For a stable fault, the same keyed PageStorage and inner ExpansionTile State survive parent rebuilds/callback removal (framework380–382), so a fresh bucket does not overwrite live _isExpanded. A changed fault creates a new State reading an empty local bucket. The nine-case host deliberately has an outer PageStorageKey; the recovery test also removes callbacks without changing fault identity.
- New test finders use actual TextButton subtypes through ancestor predicates and exact SelectableText data. All waits settle finite expansion animations after direct local widget updates; there are no unresolved HTTP/completer jobs or permanent spinners in these new fixtures. The320px/text1.8 case is prepared, not rendered or passed here.

## Existing contracts updated

Three positive raw-code contracts were affected: initial queue SERVICE_UNAVAILABLE and invalid ownership proof in the browser review file, and INVALID_USAGE_REPORT_RESPONSE across the five malformed/duplicate-target variants. Each now checks the natural-language FailureView, verifies diagnostics are absent even with skipOffstage=false, explicitly expands the scoped details, and checks the exact prefixed selectable diagnostic. Browser annotation, original editable proof/reason values, queue recovery, stale callback/request/POST assertions remain. The report test still forbids generation and device output, and now counts repository requests explicitly as zero.

Expanded invalid-proof diagnostics may scroll the old proof input offscreen, so the existing input correction explicitly brings that field into view before editing it. Successful queue recovery removes the entire FailureView, and scope replacement checks the whole lookup FailureView/failed-query label; old raw-code negative checks therefore cannot pass merely because diagnostics start collapsed.

Whole-tree text searches classify remaining uppercase literal, dynamic-code and SelectableText finders in variant-audit.json. Pairing tokens, validated diagnostic-preview request identifiers, permission/business labels and natural-language error assertions are separate UI contracts and remain unchanged. No additional raw positive generic API diagnostic finder was found by that bounded text/call-site audit.

## Limits

Only source/hash/file and read-only Git operations were performed, plus the two explicitly authorized existing-test edits. No SDK, Dart parser/AST, formatter, compiler, tests, browser, network, process inventory, install or Git mutation ran. The original181 roots remain; the new dedicated component test adds one root to182 and nine unrun cases. The browser test must stay browser-only. Current UI rendering, keyboard behavior, quota error-scroll geometry, all regressions, backend/device integration and current full analysis remain pending. Known foreign tracked WIP was unchanged.

## Final r5 fixture-loading evidence

Fresh Main and HEAD inspection showed that the malformed-target loop already supplied a new UniqueKey for every UsageReportsView. The proposed concern that those existing iterations necessarily reused one State was therefore not supported by the actual source, and is withdrawn. No production lifecycle behavior or didUpdateWidget was changed, and the existing key is retained.

This final increment strengthens coverage evidence: each iteration captures its own variant ID and load counter; after mounting it requires exactly one target load and the accumulated expected variant position. After diagnostics are expanded, the same counter must still be one. Final assertions require all five iterations and the exact loaded IDs1–5, while repository requests remain zero and all original invalid-device lists, generation denials and other business assertions remain. These are unrun assertions, not a claim that five loads have already executed.

Earlier r4 artifacts are retained as preparation history. The final changes.json and pins.json in this r5 directory bind current Main; the r4 review of the unchanged production/new component-test files and the bounded variant classification still apply.
