# r11 actual analysis: independent retained-file review

**NOT_ACCEPTED is preserved.** The only analysis failure visible in the retained records is19 info diagnostics:18 `use_build_context_synchronously` and1 `unnecessary_import`. There are0 warning/error diagnostic lines. The fixed command includes `--fatal-infos --fatal-warnings`, so its natural exit1 is consistent with that log. No additional runtime failure is visible in the reviewed files; this is a bounded record review, not proof against unrecorded faults.

## Actual execution and controls

Root reports initial b996f6/session89578 → terminal f672a5 exit1. Its retained same-handle record shows host94344, exit1, first signal64.6758028s <180, no force/emergency cleanup/failure, and post candidate/runtime pins matching. Worker34392 elapsed64.2211608s <165, SDKcalls1, tests/pub/downloads=false. Command104936 naturally exited1 and reached Job0; worker and command each report terminatedProcesses0. No deadline was reached, close fallback/provider force/postflight skip are all false. Command Job drained about10.48ms and worker Job about10.97ms after first signal, within the existing0.5s natural drain ceiling.

`commandNaturalCompleteBeforeDeadline=false` and host `naturalCompleteTerminalTimely=false` are expected for nonzero exits: their source conditions explicitly include exitCode==0. These flags do not show an additional deadline failure. The briefly retained host-Job member was recorded as own-member conhost.exe and later Job0; its causal role is not classified here. TotalProcesses13/45 is not treated as known auxiliary-process proof.

## Complete checks and raw consistency

Raw preflight/postflight are both complete:410 frozen/raw Main sources with full membership/hash match,70package rows (7 internal/63external), and3536cache files/633817159B across70trees+32fixed files. SDK/runtime/bootstrap/environment guards also report complete. This review read those fixed-worker reports and compared raw with embedded records; it did not independently rehash633MB cache payload or rerun source/control predicates. Host embedded receipt equals raw receipt; embedded pre/post/resourceAfter equal their raw files.

The three PS raw inventory arrays contain714/715/712 rows, all typed integer PID/string name/list errors, with unique PIDs, no blank names, no row/provider errors and enumerationSucceeded=true. Ordinary metadata counts show none of the original19SDK names or.test suffixes. Each gate carries fixed provider SHA f3c4349381fb6fc612b322e1a2a7ba59b6b21e4653e3212bfbac2b252028a046. No PID/name exemption or cross-snapshot PID-identity merge was used in this review.

## Post and release

Root reports e840fc post exit1. Its retained `post.json` says NOT_ACCEPTED_FILE_READBACK / Root retained-handle natural exit proof rejected, correctly stopping at actual Root exit1. It is not an independent PASS of later worker conditions. Release fc927a exit1 records windowReleased=true, sdk0/unknown0, and all three known owned PIDs absent from its717-row saved inventory. Inventory and post hashes match the release record.

Release `resultConsistent=false` is its success-only conjunction of Root0/post0/accepted status, not a reported raw-record contradiction; inspection of the fixed release script confirms that meaning. `analysisAccepted=false` remains correct even though the window was released. Release is not an analysis PASS.

The log is2685B /625ac599bc0435cc68816ff397b19f658d4a3fe81c757e5a56993e74966c6b77. Current source is bound to abb2e016650cf579fc7ad1dbccdecc682072807a; future fixes require fresh source/inputs and a new Root grant. Full181 regressions,80browser cases and UI rendering remain UNRUN. Runtime closure remains false. No post/candidate/provider/SDK/test/AST/native/process API/network was executed, no old evidence or Main/Git was modified, and no new qualification or source/runtime copy was created.
