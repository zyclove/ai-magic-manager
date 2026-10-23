# Guardian analysis r2 — environment refusal, 2026-10-21

This archive preserves the unsuccessful r2 attempt without rewriting its result.
Actual tool session `93673` (initial `303320`, final `075487`) ended naturally
with exit 1 after 43.790672 seconds. **No SDK command started (`sdkCalls: 0`), and
no analysis or tests ran.** The original result remains `NOT_ACCEPTED`.

The initial gate observed two external Java processes. The finally/postflight
check additionally found that the historical Chrome executable content pin had
changed, and the final process/resource gate still failed. The owned worker
finished naturally with an empty owned Job and no timeout/forced cleanup.
These are environment/input refusals, not analyzer diagnostics or source RED.
The final external Java processes in the original result were not owned by this
attempt and were not stopped.

`attempt/` preserves all seven original JSON/log files; `candidate/proposal.json`
preserves the exact original proposal (`5a321054ee020199025e7c40ab062f5577a0ecf3ade5ec899a131bacdce80490`).
Absolute scratch paths and the original non-accepted status remain unchanged.
This minimal record does not claim a complete relocatable candidate or new
external acceptance. The later successful r3 is archived separately at
`../guardian-full-analysis-20261023-r3/` against its own newer source snapshot.

All eight raw files are byte-for-byte copies. `.gitattributes` disables text
conversion. The inventory lists every file except its own self-hash. Creating
this archive ran no Git, SDK, candidate, tests or browser, read no private
runtime files, and changed no application source or original evidence.
