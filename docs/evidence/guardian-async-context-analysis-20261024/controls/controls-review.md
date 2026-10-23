# r11 fixed full Guardian analysis controls: static author handoff

Only new `.cache/guardian-analyze-20261023-r11-current` controls/evidence are authored. No candidate/helper/SDK/process query was executed. No Main, Git, old r10, qualification candidate, shared runtime or cache payload was written. Root still owns proposal/grant/launcher/post/actual execution and formal release.

## Fixed bindings and interfaces

- Source commit `abb2e016650cf579fc7ad1dbccdecc682072807a`; sealed source `.cache/guardian-current-20261023-r10-current`, all 410 source paths, full 181 regression root/80 case/7 selector metadata, original seven roots and all source/Git/package/cache/runtime guards retained. The metadata counts are not test execution claims.
- Input `inputs.json` 16341B SHA `b5256a52c81a0fe84e4436bd3c8ab19e51d88b65701fc6e9407e442f4ff3463d` is fixed in host and worker. Root authored this input with 35 runtime descriptors; this handoff does not claim to have independently rehashed the whole runtime/cache collection.
- Exactly four proposal controls: analysis-host.py, worker.py, owned_job.py, process-inventory.ps1. Fixed host CLI remains `analyze <exact proposal SHA>` and fixed worker accepts no args. No arbitrary command entry point is added. The native helper remains byte-identical f8b44764...141b, with no native memory-limit claim.
- Fixed PS7 path: `C:/Users/Administrator/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe`, version 7.6.5. Fixed args: -NoLogo -NoProfile -NonInteractive -File <this directory>/process-inventory.ps1, no script args. Provider script is 2439B/f3c4349381fb6fc612b322e1a2a7ba59b6b21e4653e3212bfbac2b252028a046, also bound through inputs.processInventoryProvider.

## Single complete name source

The provider performs one unfiltered module-qualified Get-Process. It emits every row, including a null/invalid field and explicit errors if a getter fails. It reads PID/ProcessName only and disposes its process objects. No command line/environment/start-time/module/creation-identity reading, SDK whitelist/filter, resource subprocess, special PID/name exemption or cross-provider merge occurs in this script.

Exact producer JSON has ten fields: schemaVersion:int1; provider; purpose; powerShellVersion:'7.6.5'; sampleStartedAtUtc/sampleFinishedAtUtc:string; enumerationSucceeded:bool; providerErrors:string[]; rowCount:int; rows:[{pid,name,errors}]. UTC strings are audit labels and are never combined with QPC deadlines.

Worker verifies the fixed helper descriptor and unique fixed PS executable runtime descriptor before each fresh call. Child-only env fixes SystemRoot/WINDIR/PATH(System32), TEMP/TMP(existing owned host-tmp), PSModulePath=<PS_HOME>/Modules and POWERSHELL_TELEMETRY_OPTOUT=1. SDK child env is byte-identical to r10.

Communication waits at most min(5 seconds, original HARD-now); only the exact Popen child handle may be force-closed, with at most min(1 second, original remaining HARD) cleanup wait. Any provider force, nonzero/stderr, timeout, invalid UTF8/partial or duplicate-key JSON, schema/type/count error, nonempty row/provider error, empty name or duplicate PID rejects the operation. Output length is checked after capture against 2MiB; this is not a hard memory quota. If cleanup cannot establish terminal within its remaining budget, the attempt remains RED and the original outer Job control is still required.

The consumer normalizes optional .exe and applies the full unchanged SDK name set plus .test suffix, case-insensitively. psutil is now used only for RAM; disk reads remain shutil. Global name snapshots do not establish process control identity or continuous absence between samples; original host/worker/command retained handles, creation FILETIME and Job accounting remain separate.

Each successful resources() result and initial-gate/launch-gate/postflight-gate file keeps original sdkProcesses/unknownProcessNames/RAM/disks and adds processNameInventory (the complete raw typed JSON) and processNameProviderScriptSha256. Invalid inventories are rejected before a valid-looking empty gate can be returned. Host independently checks the full final raw rows, typed unique PID/name/errors and derives SDK absence, in addition to the old resource thresholds.

## Timing, outcomes and preserved code

Original 180 outer / 174 host work / 165 worker / 135 command / 140 cleanup / 25 postflight ceilings and earliest anchors remain. Native OwnedJob source, complete host native monitoring block, worker natural_command/monitor_command, full cache/source/package/runtime guards, original Flutter flags and SDK env are preserved. Neither monitoring loop gained I/O/hash/fsync.

Receipt adds processNameProviderForced and postflightSkipped, both required false by worker and host acceptance. SDKcalls0 skips only the expensive full postflight rehash and records postflight={complete:false,skipped:true,reason:'SDK_NOT_STARTED',sdkCalls:0} in receipt and postflight-skipped.json. It remains NOT_ACCEPTED. SDKcalls1 still requires complete pre/post checks, no errors/forces, original command strict complete Job0 before min(START+135,firstSignal+.5), worker strict own terminal in original budgets and host strict Job0 before min(anchor+174,firstSignal+.5). No acceptance or deadline was relaxed.

Prior r10 SDKcalls0/NOT_ACCEPTED and old r9 314-second RED remain historical failures. Qualification's sdkAllowed=false manifest is unchanged; it is only native-helper provenance and is not this analysis grant. Root same-handle actual host exit before 180, actual tool terminal and full process release remain external acceptance requirements.

## Static preparation limits

Read source and all deltas only. Mechanical text/hash checks confirmed all fourteen inherited r10 utility/guard functions, git/runtime_check, worker monitor/natural functions, host native monitor block, flags and SDK env listed in control-pins. No AST/parser/compiler/formatter/import/candidate predicate/fixture/test/SDK/network was run; no new qualification case or diagnostic round was executed. All r11 behavior remains UNRUN. This is author preparation and requires independent review before any separately authorized execution. Runtime closure remains incomplete; no complete Python/PowerShell/OS/SDK installation claim.
