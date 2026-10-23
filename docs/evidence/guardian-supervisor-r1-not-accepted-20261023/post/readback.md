# Supervisor r1 failed-qualification post readback

Status: **PINS_MATCH / NATURAL_ZERO_NOT_ACCEPTED**. This is an independent file readback after the Root-authorized attempt, not a qualification rerun or an OS release gate. No SDK, fixture, candidate import, code parser, WinAPI/process API, network, Main or Git write was performed. Original candidate and receipts remain unchanged.

## Actual recorded outcome

Root execution reference supplied by Root: `dd72ce`, natural exit 1. Root's retained host was PID 101944, actual exit 1, first signaled wait at 0.2161604 seconds against its earlier 14-second limit. Root recorded no own-host force or emergency cleanup. This establishes a timely failed host result, not a successful qualification.

The inner observation records root PID 100312, retained creation FILETIME 134372237901889745, actual root exit 0, first signaled QPC 28297.0403444, and final Job accounting active 0 / total 2. It also explicitly records `forcedCleanupRequested=true`, `terminationCallSucceeded=true`, `deadlineReached=false`, and `expectedOutcomeObservedBeforeOutput=false`. Root's result preserves `qualificationAccepted=false` and `analysisAccepted=false`. Final Job zero therefore cannot be presented as an unforced natural-zero pass. `terminatedProcesses=0` does not erase the recorded successful explicit termination request.

## Mechanism and evidence boundary

In sealed `supervisor.py:69-76`, a terminal sample breaks before cleanup; otherwise a signaled root or an expired work deadline triggers own-Job termination. The recorded before/after-termination QPC values (28297.040445 / 28297.0404629), the work deadline 28304.8873177, and `deadlineReached=false` identify the signaled-but-not-terminal branch by code-path inference. The candidate conservatively rejected that state as a natural qualification.

The final sample preserves the earliest signaled timestamp, but the **complete first signaled sample was not persisted**. Its contemporaneous active count, cumulative count, and member identities cannot be independently reconstructed from the later sample. Cumulative total 2 proves neither two concurrently active members nor a known auxiliary process. The files do not establish whether the nonzero accounting reflected a still-active owned descendant, accounting convergence, or another mechanism. No member may be labelled or exempted as an auxiliary process from this evidence.

Any future change should preserve this failed original and first add immutable first-signaled/full-accounting observations and an explicit policy for signaled-root/nonzero-Job handling under the same original deadline. Merely ignoring the force, relabelling total 2, extending the deadline, or accepting eventual Job zero would not close the evidence gap. No follow-up behavior was implemented or executed here.

## Integrity and unfinished work

All six candidate, six runtime and eight delivery descriptors were rehashed, with the exact manifest and delivery SHA anchors retained. The Root launcher is exactly `082b132e7f573ee792e99afb8a27ddd5df2dae47cb242c3a871c8d444170ccfc`. The JSON readback records each descriptor and byte-identical preservation copies of Root preflight/result plus inner observation/empty console. The three other qualification case paths remain absent; those cases are UNRUN. There is no analysis or real-controller acceptance.

Live OS-wide inventory and formal shared-window release were not performed by this readback and remain Root's separate work. An initial filename lookup traversed a broader cache inventory than intended; no unrelated file contents or SDK/cache payloads were opened, and subsequent reads were limited to these candidate, Python runtime, launcher and receipt files.
