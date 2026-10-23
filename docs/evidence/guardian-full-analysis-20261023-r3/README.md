# Guardian full analysis — 2026-10-23 r3

This archive preserves the actual full Guardian analysis of commit
`080e41c66a348d48d8ac313cde77e4dd8f36cc47`: **0 errors, 0 warnings,
0 infos**. The command used `--no-pub --fatal-infos --fatal-warnings` and no
selectors. Actual tool session `20133` (initial `db2264`, final `d7a441`) ended
naturally with exit 0 after 46.2899227 seconds. The independent Root observation
also accepted this analysis. No forced termination, owned processes, or metadata
mismatches remained at release.

## Scope and limits

- The complete snapshot contains 405 committed files across Guardian and six
  shared package roots. Main and frozen membership/raw hashes matched before and
  after the analysis. The source manifest records the exact Git blobs/trees.
- The complete 70-package mapping and retained cache boundary (70 trees plus
  32 fixed rows, 3536 files / 633817159 bytes) matched before and after execution.
  The analysis projection preserves the historical parent unchanged except for
  its one Chrome executable row, which this command does not use. The unchanged
  parent manifest is referenced below without duplicating its 725122 bytes.
- This is a successful analysis, not test, browser, backend, deployment, live
  provider, or whole-product acceptance. The 138 Guardian test files (103 VM and
  35 browser) and 1249 declarations in `test-scope.json` are static inventory,
  not an executed test count. Nine additional shared-package test files are
  separately listed in that inventory.
- Execution ran offline without pub/downloads/cache copying or service changes.
  Archived preparation receipts predate execution and honestly retain their
  original `UNRUN`/`attemptExists: false` fields. The attempt and independent
  observation are the later actual outcome.

## Preserved material

`attempt/` contains every actual raw log/JSON receipt. `candidate/` preserves the
approved controller, worker, native Job helper, proposal, schemas, mechanical
diffs, static reviews, and the two Root review/observation scripts. `inputs/`
contains the source, dependency, cache projection, test inventory, package maps,
and preparation receipts; `preparation/` preserves the exact extraction script.

The parent is
`../guardian-baseline-analysis-20261021/inputs/cache-content-20261021-r1.json`,
SHA-256 `0027b4f8d65b9054e273b3c98a8b62f8de963fe9b59e054bf750eaae1cc6f3c2`.
It describes a limited allowlist, not every file in the SDK or browser install.

All 34 raw files are byte-for-byte copies, including original absolute paths and
historical statuses. This is an evidence archive, not a relocated runnable
candidate. `.gitattributes` disables text conversion. `archive-inventory.json`
records every file except its own self-hash, original path, byte count and
SHA-256. Archive creation invoked no Git, SDK, tests, browser or candidate code,
read no private runtime files, and changed no application source.
