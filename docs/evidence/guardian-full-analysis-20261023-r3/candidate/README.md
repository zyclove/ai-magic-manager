# Fixed Guardian analysis candidate

This is a static candidate for one full Guardian analysis phase. No candidate module or SDK has been imported or run during preparation. The Root input is frozen at `c1a91fc4d62ba4ce162a0f289560887d8c7dfc3b2f98370b4a606e7c84b07305`. Root must review and approve the final proposal digest before one invocation; the existing controller requires that exact digest as its only argument.

The outer controller is a mechanical copy of `.cache/id17-current33-20261021-r1/controller.py`, SHA-256 `7084a93b4073b946b389812ff8faa155e5623f40661729f5ae72482c261ec0ba`. Its complete deadline is 210 seconds, its soft cutoff is 204 seconds, and only budgets, state labels and the phase scope differ. Its private Job, worker handshake, direct hard exit, natural Job drain and cleanup receipts are retained.

`heap1536_windows_job.py` is copied byte for byte from `.cache/family-payment-terminal-20261021/heap1536_windows_job.py`, SHA-256 `4965e39eecfe70c7eeeb7ce317c0c06f4ae484d36f025706fff3a669cec4ab12`. The worker uses this existing native helper to create the one command in a nested private Job atomically and retain its native process handle through postflight checks.

The only SDK command is:

```text
C:/Windows/System32/cmd.exe /d /v:off /c D:/softwares/flutter/bin/flutter.bat --no-version-check --suppress-analytics analyze --no-pub --fatal-infos --fatal-warnings
```

Its working directory is the existing frozen `.cache/guardian-current-20261023-r3/src/apps/guardian`. It has no selector. The worker's complete budget is 195 seconds. At launch, the command deadline is the earlier of 180 seconds from launch and 30 seconds before the worker deadline. Five seconds are reserved for command cleanup and at least 25 seconds for complete postflight checks. Any timeout or forced termination permanently prevents acceptance, even if all later hashes match.

Before and after the command, the worker checks the complete 405-file raw Git snapshot, the corresponding Main raw hashes and complete source membership, current Git trees and blobs for all seven fixed roots, the complete rebased 70-package configuration, all 70 cache trees and 32 fixed runtime files (3,536 files) in the exact analysis-only parent projection, Root's control/bootstrap pins, and SDK readiness. Source membership excludes only `.dart_tool`, `build`, and `.idea` directories and the four exact file names `.flutter-plugins`, `.flutter-plugins-dependencies`, `guardian.iml`, and `device_operations_showcase.iml`. Unknown additions outside those exclusions fail the check.

Initial, launch and final resource gates require zero observed SDK processes, zero unknown process names (excluding Windows PIDs 0 and 4), at least 2 GiB available RAM, and at least 2 GiB free on C: and D:. Process TEMP/TMP are confined to the new single-use `attempt/tmp`; Pub and Flutter storage URLs point to `http://127.0.0.1:9`. The worker creates no source or cache copy and never runs pub.

SDK readiness follows the actual fixed `shared.bat`: the pinned tool snapshot must exist, the quoted compile-key stamp must match the fixed SDK revision with empty `FLUTTER_TOOL_ARGS`, the tool pubspec must not be newer than its lock, the engine/Dart stamp must match `engine.version`, and `bin/internal/bootstrap.bat` must remain absent. Snapshot mtime is not compared with pubspec mtime because the actual launcher does not make that comparison. Snapshot content remains covered by the complete cache hash checks. The child PATH is confined to the three Root-approved Windows, Git and Dart directories; nonempty inherited SDK override variables are refused.

The attempt directory is created once by the existing outer controller. Logs and JSON evidence use exclusive creation. Any existing attempt or result is preserved. No retry or renamed attempt is built into this candidate. Worker success additionally requires natural exit code zero, an empty nested Job, the expected `No issues found!` log, complete matching postflight pins, and all checks within the full worker budget. Root's actual external observation and acceptance remain required.

Preparation validation is static syntax parsing only. Runtime watchdog behavior is inherited from the two supplied components; this Guardian candidate has not been exercised.

This r3 candidate is mechanically rebased from the actual r1 analysis candidate (session 63918, natural exit 1, 17 analyzer infos). That historical result did not accept the baseline and does not validate this new commit. The r3 controller and native helper are byte-identical to r1; the worker frozen-source directory, Root input digest, source count and analysis-only cache projection checks changed. The projection preserves 70 complete parent trees and 32 fixed rows (3536 files); only unused Chrome is excluded. Full runtime preflight and postflight still hash all 3536 files. The historical parent is preserved, not recollected.
