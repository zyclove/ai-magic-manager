# Independent Schedule scope review

Static review only. No clear blocking regression was found in the reviewed Schedule entry path or appended tests. This is not runtime acceptance.

Reviewed `scheduleEditor` and the Schedule portion of `editors.dart`, the final appended tests, and the necessary scope, owned-dialog, API, session, Flutter route and pinned HTTP MockClient context. The entry captures scope before presenting the dialog; fallback scopes are disposed and borrowed scopes are retained; bound clients are not closed by the editor. Scope loss is sticky, including same-frame away/back and Widget session/root replacement. API guards remain effective after client acquisition. Covered in-flight completion uses current scope while new interaction requires the current route. Authentication/access revocation removes sensitive editor state, and covered unknown-result confirmation removes its own route. Build-phase cleanup is deferred safely.

The non-Schedule tail starting at `const ruleEffects` remains byte exact: 34,495 bytes, SHA256 `76d99689d66e78a39bf62367e921f16352eddd90878276b4d59103aa2b6cd240`.

The original 13 scenarios and 71 expectations were retained. The appended 14 scenarios cover awaited-client loss, four same-frame scope changes, covered confirmation, two late responses after scope loss, three server revocations, the reauthentication control and two Widget replacements. The actual pinned HTTP MockClient adapts BaseRequest to Request before invoking its typed handler. The covered-dialog helper uses an existing ScheduleEditor context; a nonopaque dialog does not remove that context. No clear compile or endless-wait blocker was identified by static reading.

All 14 new scenarios and the resulting 27-scenario test file are UNRUN for this source revision. No SDK, Dart, formatter, AST, native/process API, fixture, browser, HTTP or test invocation was performed for this review. Entry pre-push timing, borrowed-scope disposal and transport ownership were reviewed in code, not claimed as directly exercised by the 14 additions. Frozen B6/r16 evidence applies to its older source and does not validate this revision.

Only this new review directory was written. Production/test source and Git were not modified.
