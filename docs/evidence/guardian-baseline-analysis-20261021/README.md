# Guardian baseline analysis — 2026-10-21

This archive preserves the complete offline analysis record for historical Git commit `08a335a634b00e67e4163aa4f07bfa2aa010d4b1`: 403 source files across the seven roots listed in `inputs/source-manifest.json` and `candidate/proposal.json`.

## Actual result

- Actual tool session: **63918**; initial chunk **a744af**; final chunk **bbd415**.
- Natural outer exit: **1**, in **62.83000679999532 seconds**. The retained command process handle reported exit 1 and an empty owned Job. No timeout or forced termination occurred.
- Full Guardian analysis reported **17 info diagnostics**, all `use_build_context_synchronously`; **0 errors and 0 warnings**. The requested fatal-info policy therefore rejected the analysis. Original `NOT_ACCEPTED` results are preserved without alteration.
- Preflight and postflight matched all 403 frozen/current source files, seven Git root trees, 70 package mappings, and 3,537 cached/runtime input files (638,417,631 bytes).
- No tests, pub command, dependency download or upgrade, real provider call, service update, or deployment was performed. Source files were not changed by the runner.

## Evidence boundary

`attempt/external-observation-root.json` records Root's independent observation of the actual terminal result and process release. `attempt/out/analyze.log` is the original diagnostic log. Candidate preparation files under `candidate/` were written before execution; their static-only wording is not runtime acceptance.

This is a **historical baseline**, not verification of the source corrections now being developed. Those changes require a fresh analysis and their own tests.

Only regular evidence and input metadata were copied, byte for byte. No 403-file source copy, SDK binary, temporary-directory contents, private environment, credentials, or keys are included. Hosted cache locations in metadata identify existing offline dependencies; the metadata does not contain their source files.

`archive-inventory.json` lists exact paths, byte counts, SHA-256 values, source provenance, and the non-executing sensitive-field scan. `.gitattributes` preserves raw evidence line endings when committed.
