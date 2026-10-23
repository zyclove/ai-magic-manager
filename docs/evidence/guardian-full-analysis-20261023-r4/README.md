# Guardian full analysis — 2026-10-23 r4

This archive preserves the externally accepted full Guardian analysis of commit
`fa2148954ccec749f7d58c38184a208085bfe181`: **0 errors, 0 warnings,
0 infos**. The command used `--no-pub --fatal-infos --fatal-warnings` with no
selectors. Actual tool session `89525` (initial `25badb`, intermediate `13affd`,
final `5c9348`) ended naturally with exit 0 after 45.5964088 seconds. Root's
independent observation (actual `ac688f`) accepted the analysis and formal release.

## Scope and limits

- The complete snapshot contains 406 committed files across Guardian and six
  shared package roots. Main and frozen membership/raw hashes and the current
  seven Git trees matched before and after analysis. The source manifest records
  the exact Git blobs/trees. Later commits outside these roots do not alter this
  source identity.
- All 70 package mappings and the retained cache boundary (70 trees plus 32
  fixed rows, 3536 files / 633817159 bytes) matched before and after execution.
  The analysis projection preserves its historical parent except for the sole
  Chrome executable row, unused by this command. This is a limited allowlist,
  not a pin of every SDK or browser file.
- Native command and outer controller both exited naturally with code 0. There
  was no timeout, forced termination or owned cleanup; retained process handles
  were terminal and the private Job contained 0 active processes. Root also
  verified the conservative strict deadline bound: the complete outer elapsed
  45.5964088 seconds was less than launch worker elapsed 18.2104604 plus command
  budget 116.7895396 seconds, totaling 135 seconds.
- Release observation recorded no SDK processes or unknown process names, and
  owned PIDs 53964 and 57848 were absent. These are observations at analysis
  release, not a statement about later separate executions.
- **Tests: NOT_RUN in this analysis.** This is analysis acceptance only. It does
  not accept tests, a browser run, backend, deployment, live providers, or the
  whole product. The separate Browser38 execution outcome is excluded.
- The actual analysis used one SDK invocation, no pub, downloads, cache copying,
  service changes, or Main/frozen source writes. Preparation and static review
  records honestly retain their earlier UNRUN/attempt-absent status; the later
  attempt and external observation provide the actual result.

## Preserved material

`attempt/` contains all 12 actual raw files, including the 189-byte analysis log.
`candidate/` and `preparation/` preserve all 10 pinned candidate files, the exact
proposal and seal, and Root's external observer source. `inputs/` preserves
the source manifest, dependency pins, original/frozen/generated package maps,
analysis inputs and cache projection. Its source-snapshot proposal and seal
record shared snapshot provenance only. `reviews/` preserves the independent
static review receipt. `summary.json` records the outcome and actual tool
references, without inventing a raw copy of the tool transcript.

The full historical parent is retained at
`../guardian-baseline-analysis-20261021/inputs/cache-content-20261021-r1.json`,
SHA-256 `0027b4f8d65b9054e273b3c98a8b62f8de963fe9b59e054bf750eaae1cc6f3c2`.
`archive-inventory.json` maps all 29 historical metadata pins to byte-exact
durable archives, including the prior r3 records, without duplicating the SDK
or source snapshot.

All 35 raw files are byte-for-byte copies with original paths and historical
statuses preserved. `.gitattributes` disables text conversion. The inventory
lists every archive file except its own self-hash. This is an evidence copy,
not a runnable relocation. Archive creation ran no Git, SDK, test, browser,
candidate controller/worker/helper or private-runtime collector, changed no
application source, and preserved all caches and the separate browser attempt.
