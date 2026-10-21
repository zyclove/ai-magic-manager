# Frozen identity baseline verify candidate

Plan: original32 baseline only, from r4 fixed source/manifest and Git tree 098c8e75a7107876bdf31aba106882ff65b7d2b3. Main/WIP is never a source fallback. Historical r4 artifacts are read-only.

Static preparation only; no SDK, test, build, source snapshot or Maven-cache copy is performed by preparing these files. A separately approved proposal digest and exclusive runtime grant are required. One attempt uses CreateNew files and refuses reuse.

Mature execution components: Maven/Surefire/JAR plugin, installed pywin32 Windows Job Objects, Python subprocess/XML/ZIP. The worker blocks before imports until assigned to its private kill-on-close job. The real supervisor bounds preparation, hashes, gates, Maven, postflight and publication to 180 seconds; 6 seconds are reserved for cleanup. Only the owned job may be terminated; any forced cleanup invalidates acceptance.

Acceptance requires original13 main +12 test compiler inputs; exact12 suites/71 method cases, zero failures/errors/skips; JAR matching all32 main classes and4 resources with no bundled test/dependency classes; unchanged original32 baseline and both3788-file caches; natural terminal worker/job and fresh SDK0. Module and real Keycloak/MySQL runtime acceptance remain separate.

Ruling: the coordinator explicitly allows only static preparation now. Runtime watchdog/Job behavior and Maven tests are NOT dynamically verified at this stage; red/green/runtime exercise is deferred to a new explicit grant. Do not claim the candidate passed runtime checks. No production/test source or dependency change is made.

The child JVM environment removes only the21 fixed consumer/SMS/WeChat/provider keys listed in proposal.json before fetching their values; the test itself may set its fake HMAC_FILE. Java heap is512MiB per task JVM via process-local JAVA_TOOL_OPTIONS, with task TEMP/TMP and java.io.tmpdir. No global environment is changed.

## r2 Job API correction and retained r1 evidence

The coordinator observed r1 actual chunk 793a8c terminate naturally with exit 1 in 0.06099 seconds: `CreateJobObject(None, None)` raised `TypeError: None is not a valid string in this context`. Worker PID remained null; no worker, Maven or SDK was started. The r1 attempt and all its original results are retained unchanged.

The coordinator then ran an empty-Job control API probe: `win32job.CreateJobObject(None, '')` succeeded, reported ActiveProcesses=0 and closed only its own empty Job (natural exit 0, 0.201 seconds). This probe is not a test of the worker, Maven or identity module.

This independent six-file r2 candidate changes exactly that one controller call from a None name to an empty Unicode string. The worker, settings and expected tests are byte-identical to r1; all 32-source/13+12-input/12-suite/71-method/JAR/dual3788-cache/512MiB/2GiB/180-second/owned-Job requirements remain unchanged. Only controller and README pins are updated in the proposal. Preparation is static only: no candidate import/execution, SDK, module source copy or cache copy. A new exclusive grant and actual terminal/result review are required; r1 is never reused as an attempt.

R3 adds only a natural Job-accounting drain of at most one second, bounded by the unchanged working cutoff, after an already-terminal worker and before considering forced cleanup. Root controlled Python-only handshake observed child exit0 with immediate Job ActiveProcesses1 (R1), then exit0/Job0 after bounded drain (R2, 0.0686201s). No SDK or business test was run by those probes. Original probes and R1 failure remain unchanged. All original71 verification requirements remain unchanged.
