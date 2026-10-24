# Browser13 B4 — minimal independent static incremental review

Disposition: NO_NEW_CONCRETE_STATIC_BLOCKER in the canonical Git-trust delta. Read-only source/metadata checks51c823,67495b,fc6341 naturally exited0. No SDK, fixture, candidate import/compile, Git invocation, browser, network or process API was used in this B4 review. B4 application execution remains UNRUN. No grant or attempt was created.

Reviewed final files:

- Input20240/906ca7d4c49602b8cb59fb9bb3cdd058f6bd1a0c6f1e10dae363c4a64fc17311
- proposal11057/849e0819fdce2cbb794f0c008a4e5c20aa5eff9517104c2d6902c970aac2a348
- Root9255/6edc2809f89ec8f63d8dc51e414a82ba514214cf26d0431d4342ae01aa667395
- release4445/98a99e501d6106349b8cd0b88df6b8afdf7f964d9b03276819572489993ea251
- post55004/5aa635100c49e676b5ec4796781812ea27c5780215da847474b30734ba1920ce
- sealed preparation8538/26fdbba052b131fb4044a1f83d06b2419582bdc56d4ccac4349bd256eb98e942

All27 sealed small-file pins were actually read and matched. All28 listed R3 preservation items, including its failed actual evidence, matched their recorded raw pins. This is an inventory-bound preservation check, not a claim to have rehashed every historical scratch item. The seven core hashes were rechecked immediately before writing this review; no drift occurred.

The complete B4-vs-B3 patches were read. Independent text-only inverse application recovered the actual B3 raw bytes exactly for all five changed controls: worker, host, post, Root and release. No unreviewed code delta is hidden outside the reviewed patch hunks.

The only behavioral changes are the five previously diagnosed consistency sites: worker Git -c safe.directory now uses Path(cwd).as_posix(); its two SDK-child environment values use REPO/SDK.as_posix(); its launch record writes that exact pair; independent post expects the same exact pair; Root's command-scoped value uses an equivalent backslash-to-forward-slash replacement. Actual cwd values, the worker's REPO-or-SDK allowlist, Git isolation and optional-lock settings, and the strict two-directory boundary are unchanged. No wildcard trust, global config, owner or permission change is introduced. The canonical arguments remain present even if Root later executes with an already-authorized elevated account.

The corrected values are the same values proven by the preceding independent read-only before/after experiment: all five isolated pairs changed only the trust spelling, from128 to0; project/SDK revisions matched and all413 source path→blob rows matched the fixed r15 manifest. This B4 review does not repeat those Git calls. Its evidence files are directly referenced by the seal rather than treated as a new SDK qualification.

After B4→B3 namespace normalization, Input differs only by createdAtUtc. Its qualification descriptor remains the exact original B3 file1307/6e8ba3d2436bfa7ba1c80bad1bb24856f3eca27de6bf8476fd1c297c773a070a. The original descriptor was actually rehashed. Worker481–485 and post557–564 bind the code hash and original actual qualification evidence; they do not require that qualification to be rewritten into the new directory. The observer is byte-identical29439/34e80553205db29267baf4299821ff40111adbc79bd2e83e49fbf20282eb5a3f. No new fixture is required or claimed here.

Runtime descriptor rows remain exactly the same43; cache projection, f8 native helper, process provider, reporter, strict Chrome guard and thirteen-case contract are byte-identical to B3. Source006ee45/r15/413/full183, selected1root/13exact cases, HTML target, original180/174/165/135/140/post25 budgets, natural-exit/Job0/0.5s drain and forced-failure rejection are retained through the exact control inverses. This minimal review relies on the preceding full B3 static review for unchanged native/renderer/diagnostic logic and does not repeat its runtime/payload checks.

R3 stays RED with SDK0 and tests not run. No B4 wrapper or reporter outcome exists at this preparation checkpoint. Root must still close its actual execution plan, establish the resource window and handle any live process/result/release through the original controls. This static conclusion neither grants that execution nor signs the other182 regression roots.
