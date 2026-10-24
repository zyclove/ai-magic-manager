# Browser13 R3 Git safe-directory diagnosis — independent actual read-only comparison

Conclusion: the R3 worker failed before SDK creation because its command-scoped Git trust value used a Windows backslash path that this Git invocation did not accept for the canonical repository path. In the same isolated child environment, changing only that safe.directory value to forward slashes makes the intended read-only queries succeed. The equivalent two-directory SDK-child environment exhibits the same before/after behavior. No source failure, Flutter failure or browser case result is inferred from R3.

R3's original worker-console.log and receipt remain untouched: CalledProcessError128 on rev-parse HEAD, sdkCalls0, testsRun=false, postflightSkipped=true, no forced termination, worker elapsed3.4801314s. Root's separately reported host/post/release RED history remains RED even though its resource window was released. No R3 grant or attempt is reused here.

## Actual before/after proof

Two isolated series executed only the authorized Git rev-parse/ls-tree reads, with the pinned Git executable at C:\Program Files\Git\cmd\git.exe. No SDK, browser, observer, fixture, global-process query, Git write, configuration write, ownership change, permission change or source edit occurred. No global or wildcard safe-directory allowance was used.

1. Worker-style -c trust (d04a04 natural0): all inherited Git variables were omitted by constructing the Root OS-variable whitelist from scratch, with the same bounded PATH and GIT_CONFIG_NOSYSTEM=1, GIT_CONFIG_GLOBAL=NUL, GIT_OPTIONAL_LOCKS=0, GIT_TERMINAL_PROMPT=0. The argv retained core.fsmonitor=false and core.untrackedCache=false. Each child had a5s maximum. TEMP/TMP pointed only at this diagnosis's own directory; no machine/user environment was changed.

| Query/cwd | safe.directory backslashes | safe.directory forward slashes |
|---|---|---|
| Project rev-parse HEAD | exit128; dubious ownership; empty stdout | exit0;006ee45850c9b6b0f90570d9478bced3beb0e0fe |
| SDK rev-parse HEAD | exit128; dubious ownership; empty stdout | exit0;761747bfc538b5af34aa0d3fac380f1bc331ec49 |
| Project ls-tree -rz HEAD -- seven fixed source roots | exit128; empty stdout | exit0;413 NUL-terminated rows,42370 raw bytes |

The before stderr identifies BUILTIN/Administrators as owner and UFO/CodexSandboxOffline as the querying account, matching the actual worker error. The after stderr is empty. The safe value is the sole difference within each paired command. The forward-slash413 path→Git blob map was compared with the pinned r15 source-manifest.json and matches exactly; source checks were neither skipped nor weakened.

2. SDK-child environment mechanism (5b0fcc natural0): the same clean configuration context plus exactly GIT_CONFIG_COUNT=2, two safe.directory keys and values restricted to this project and SDK. No -c safe-directory switch was added to these children. With both values expressed using backslashes, project and SDK rev-parse both exit128. With both expressed as Path.as_posix(), both exit0 and return the same expected fixed revisions. This verifies the environment-based mechanism that the future Flutter child would inherit without invoking Flutter.

The whitelist removes any caller's unrelated GIT_* injections by construction. It does not read or report another process's environment. Parent dirty-config contents are not used to mask the failure. System/global Git config is disabled for both before and after, so the observation does not rely on inherited per-user trust.

## All relevant construction sites

- worker.py:257–268 is the only direct Git helper. It explicitly restricts cwd to REPO or SDK (:259), uses subprocess cwd=cwd (:266), and currently constructs `-c safe.directory=` from str(cwd) (:263). Source checks call it for project HEAD/seven-root trees/ls-tree (:314–319); runtime bootstrap calls it for SDK HEAD (:490).
- The worker's SDK command runs in the frozen Guardian module. Its child environment at800–802 gives Git exactly two safe.directory entries, currently str(REPO) and str(SDK). The launch receipt at835 records the same list. Those environment values require the identical canonical spelling correction; the allowed directories and actual cwd need not change.
- analysis-host.py has no direct Git invocation. It copies its already-cleared Root environment at482–483, locally overrides host TEMP/TMP, and launches the worker with HERE as cwd at507–508. Therefore the worker cannot rely on caller Git-trust injection for success.
- The Root launcher queries project HEAD with `-c safe.directory=$taskRepository -C $taskRepository` at38. Its own query occurs before child Environment.Clear, but it should still use the same explicit canonical trust value so correctness does not depend on caller/global trust. Its subsequent child Environment.Clear at65 and whitelist66–70 deliberately remove inherited Git configuration. Host WorkingDirectory is the candidate directory (:63).
- Independent post.py737–739 verifies launch.sdkProcessSafeDirectories is exactly the project/SDK list. When the future worker records canonical values, this expected list must use the equivalent forward-slash representation while retaining the strict two-directory set/order. This is an evidence-format alignment, not a broader trust allowance.
- The release script contains no Git executable/safe.directory call. It needs no Git-behavior change for this fault, apart from its ordinary new-stage path/hash bindings.

## Minimal prospective correction — not executed here

In a new immutable B4 bundle, keep cwd checks, repositories, source identity, raw-tree checks, cache/runtime closure, deadlines, thirteen-case target, browser observer and strict success requirements. Only express the command-scoped safe.directory values as absolute forward-slash paths, for example Path(cwd).as_posix() in Python and an equivalent slash conversion in Root's exact value. Do so for both worker Git reads and the two SDK-child environment values; keep receipt/post expectations consistent. Preserve R3 byte-for-byte as a preflight rejection. Do not add safe.directory=*, change global config, alter owner/permissions or invoke a different source/SDK.

The actual ten read-only queries above prove this minimal Git spelling correction for the two allowed directories and both scoped configuration mechanisms. They do not prove B4 controls are correctly bound or that B4 tests will pass. B4 still needs its own final static bundle review, new Root grant and resource window; all SDK/application tests remain UNRUN in this investigation.

## Evidence preservation

actual-git-before-after.json contains each exact argv/cwd/exit, bounded elapsed time and stdout/stderr pins; actual-sdk-git-env-before-after.json contains the four environment-mechanism results and the413-map equality. Raw stdout/stderr files are preserved without newline normalization, including the successful NUL-delimited tree. pins.json hashes these outputs and the original R3/source files used. Only this new diagnosis directory is written. Read-only source calls d3455f/f28416/cb7ef7/b126f3/6d7013 and actual Git comparisons d04a04/5b0fcc completed naturally0.
