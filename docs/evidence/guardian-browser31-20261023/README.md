# Guardian browser regressions — 2026-10-23

## Actual outcomes

The first execution (session 1823) did not reach business tests: the implicit auto renderer requested CanvasKit resources that the local test server returned 404. This is not an application assertion failure or a pass.

The independently prepared HTML execution (session 38719) completed all 31 visible cases: **30 success, 1 error, 0 skipped**. The sole error is `managed entry reloads and enables refresh after generation change`. The test's initial and changed-generation readiness counts (1 and 2) passed. Its exact-type finder then missed the private subtype returned by `OutlinedButton.icon`, throwing `No element` before checking the callback. The approval/help suite's 19 cases and audit/export suite's 4 cases individually succeeded in this execution.

Both original executions remain **NOT_ACCEPTED**. Their command Jobs required cleanup at the fixed deadline. HTML native root exited 1; final owned Jobs were empty and all 405 source / 3,537 cache files matched postflight. The HTML postflight resource gate failed. Individual case successes do not establish a natural, accepted whole run.

## Fixture correction

The existing test now finds the outlined button through its text ancestor and `bySubtype<OutlinedButton>()`, checks uniqueness and its enabled callback, scrolls it into view, clicks it, then requires the third readiness request. It retains the same case name, original assertions and 31-case selection. Product code was unchanged for this correction.

The corrected test is **UNRUN**. Available RAM dropped below the shared validation threshold, so a new frozen candidate and separately granted window are required before running it. No old receipt has been rewritten as passing.

## Preserved evidence

`inventory.json` records each byte-for-byte archive's original relative path, byte count and SHA-256. Both revisions include raw reporter output, native/outer receipts, launch/resource/postflight observations and execution controls. The source, dependency and refreshed Chrome cache manifests are preserved with the original name contract. `diagnosis/` contains the independent failure investigation; `fixture-before.dart` preserves the failing fixture. These files describe local offline verification only; they do not prove deployment, authenticated user journeys, real devices or external providers.
