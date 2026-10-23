# Full Guardian analysis r6 — static candidate, UNRUN

This candidate reuses the sealed 408-file seven-root snapshot at commit
88871eb69f16012e04ad4d8aa58209edea791e4a. It copies no source tree and no cache
contents. Full Main/frozen membership, raw SHA-256, Git trees and blobs, and all
70 package mappings remain required before and after the command.

The only command is flutter.bat --no-version-check --suppress-analytics analyze
--no-pub --fatal-infos --fatal-warnings, without file selectors, from the frozen
Guardian package. It analyzes the full Guardian source and tests; it executes no
application tests. The prior accepted r5 result covers source407 only. All new
source408 analysis and prepared browser67 cases remain UNRUN.

Controller and native helper are byte identical to actually accepted r5. Worker
AST differs only in FROZEN path, INPUT_SHA256, and the source_check boundary 407
to 408. Every other worker node, including budget, runtime/cache checks, command
and cleanup, is unchanged. This adaptation does not repeat any budget rewrites.

Budget remains outer180 / soft174 / worker165 / commandcap150 / cleanup5 and
complete postflight reserve25 seconds. The dynamic command deadline is at most
worker-relative135 seconds and cleanup at most140. Full preflight consumes part
of this allocation. RAM and each C:/D: minimum remain2GiB. Fresh SDK0/unknown0
and an explicit Root grant are required; a resource snapshot never grants a run.

The analysis-only cache projection is byte identical to r5: the historical parent
minus only Chrome unused by analyze, preserving70 trees,32 fixed files and3536
file pins /633817159 bytes. Projection metadata is copied; runtime contents are
not freshly rehashed during this preparation. Full pre/post rehash is mandatory
at execution. Historical dependency seed access errors remain historical facts.

All101 r5 proposal pins are retained as historical references, plus its proposal,
seal and actual result/receipt/launch/log/external observer evidence. The new
snapshot seal and every non-source metadata file under that seal are pinned too.
No inherited acceptance is claimed for this new candidate.

Acceptance requires natural native and worker/outer exit0, No issues found!,
fatal warnings/infos, no timeout or forced termination, retained process handle
terminal state, all private Jobs0, complete source/package/cache/runtime postflight
and fresh resource gates. Root must independently check actual terminal output
and the strict complete outer elapsed bound against launch.workerElapsedAtLaunch
+ launch.commandBudgetSeconds, or require actual terminal timing evidence.
Cleanup never upgrades a failed or timed-out result.

executionApproved=false; no attempt directory, candidate import, SDK call,
application test, browser, pub, download, network call, Main/Git write, service
change, deployment or automatic chaining occurred. Python AST parsing is not Dart
parsing, type checking or application test execution. Root independently reviews
and authorizes any later run.
