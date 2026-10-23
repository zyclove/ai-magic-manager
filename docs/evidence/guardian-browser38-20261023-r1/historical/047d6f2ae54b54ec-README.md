# Guardian browser31 HTML r2 static candidate

This candidate retains source commit `080e41c66a348d48d8ac313cde77e4dd8f36cc47`, all 405 files in the seven fixed roots, and exactly the same three physical suites with 8 + 4 + 19 = 31 expected visible names. It reuses the complete frozen `guardian-browser31-20261023-r1/src` and existing generated build cache. No source tree or package cache is copied. All source manifest, 70 package mappings, dependency seed, internal root URIs, and cache manifest pins stay identical to r1.

The one proposed application command is:

```text
C:/Windows/System32/cmd.exe /d /v:off /c D:/softwares/flutter/bin/flutter.bat --no-version-check --suppress-analytics test --no-pub --platform=chrome --web-renderer=html --reporter=json test/workspace_flow_entry_browser_test.dart test/audit_export_route_test.dart test/approval_help_flow_browser_test.dart
```

Project README and deployment/local startup scripts explicitly select HTML rendering. The r1 actual attempt timed out during loading, after local CanvasKit requests returned 404, with zero business cases started. Its original NOT_ACCEPTED status and evidence remain preserved. That result establishes no application pass or failure. Flutter 3.22.2 internally fixes web test concurrency to one; omitting the unsupported explicit concurrency flag removes its plain status notice.

The controller, retained native handle/Job helper, reporter validator, and owned Chrome observer are byte-identical to r1. The worker has only three necessary changes: HTML flag replacing unsupported concurrency, frozen source path referencing r1, and the new input hash. Input metadata changes only creation time, scope, and the paths of the identical local reporter and observer copies. Mechanical diffs record every difference.

Budgets remain outer 510 seconds, soft cutoff 504, worker 495, command cap 480, cleanup reserve 5, and full postflight reserve at least 25 seconds. Source405, all 70 package mappings, full 3537 runtime/cache files, control and historical metadata are required before and after execution. Global SDK0, unknown-process0, at least 2 GiB RAM and 2 GiB free on C:/D: remain required. Only one single-use attempt is permitted, with process-local TEMP/TMP, a new owned Chrome profile, headless arguments and a loopback test server target.

Acceptance still requires natural native zero, terminal retained handle and Job0, exact protocol 0.1.1 evidence for three Chrome suite paths and all 31 unique expected visible successful names, no failure/error/skip, complete postflight, and independent outer natural terminal observation. No suiteDone event is invented. The inherited native polling boundary requires Root's conservative external total elapsed to be strictly less than launch.workerElapsedAtLaunch + launch.commandBudgetSeconds, or additional actual terminal timing evidence. Same-profile Chrome startup recovery retries remain conservatively rejected; an observer rejection is never ignored.

The original 32-negative plus two-positive synthetic metadata fixtures are referenced with their original pins and were not rerun for r2. Preparation and sealing only read files/Git metadata, inspect ASTs, and write new metadata under this candidate. No candidate module, worker, helper, SDK, application, browser or network call is executed. There is no r2 attempt directory or execution authorization. The whole SDK and Chrome installation remain outside the pin claim.
