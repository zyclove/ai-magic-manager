# Final incremental static review — exact QA commit helper

Reviewed final helper: D:\codes\mobile\ai-manager\.cache\guardian-qa-exact-commit-20261024-r1.py, 8539 bytes, SHA256 ca90c035e120a9ecbf3cc19366b61665025efef758bd3b000febe2368d079fa4. Full numbered read 1fbf5e naturally exited0; the same bytes were rechecked before writing this supplement.

Disposition: NO_NEW_CONCRETE_STATIC_BLOCKER within the requested exact-path/raw-byte/shared-index/expected-parent/recovery scope. This is not an execution grant or proof of successful staging/commit. The stage plan is still absent. The helper, Git, SDK, fixture and browser were not executed. All actual stage/commit/readback behavior remains UNRUN.

The previous 3531-byte/42ff9022 original review and 7696-byte/a89aad27 review are preserved as historical candidates. The already-sealed r2 review.md/pins.json describe the latter, not this final version. This final-review.md/final-pins.json pair is additive and does not overwrite either history.

## Incremental recovery correction

Before update-ref is invoked, lines119–129 exclusively create and fsync commit-intent.json containing candidate ID, expected parent, explicit branch, exact tree, original/private index SHA256, own lock identity and the stage-plan file SHA256. Line131 sets cas_may_have_happened before starting the CAS child at132. Finally142–145 deletes the owned lock only while the CAS is definitely not yet attempted and only after identity validation. A child failure or interruption after the attempt boundary conservatively leaves the lock and durable intent for independent recovery. Successful publication still checks its prepared lock bytes/identity and atomically replaces the shared index (133–136). If later verification/receipt writing fails, the intent survives. This closes the earlier false-pre-CAS cleanup gap; it does not pretend that ref/index publication is one filesystem atomic operation.

## Earlier protections retained

- Stage uses a private index seeded from the explicit parent and exact raw object IDs. Candidate tree path set and each blob's fixed length/SHA256/raw object SHA1 are verified directly, avoiding mutable working files as the final oracle.
- Commit uses an exclusive shared index lock, checks the original shared-index raw SHA, holds the lock file through expected-parent CAS and publishes the prepared private-index bytes by atomic replacement. Ordinary cooperating Git index operations cannot stage foreign work into that fixed candidate.
- commit-tree takes the explicit planned parent; the candidate is checked before update-ref of refs/heads/dev with the expected old parent. Concurrent advancement of that ref makes publication fail rather than silently attach to a new parent.
- Explicit require failures remain active, optimized Python is rejected, and existing hook/signing requirements fail closed instead of being bypassed. Source/worktree content is read; no source edit, push or deployment is implemented.

## Execution limits

The caller still must close and pin the actual stage plan, establish the intended repository/environment and current parent/index/hook prerequisites, retain a stable task-owned private index/receipts, and inspect any failure or retained lock/journal before continuing. This reviewer has not checked those runtime facts or the final archive path list because the plan does not exist. The intent's on-disk plan SHA is useful evidence only when the caller keeps that fixed plan unchanged during the operation. Do not infer broader Git-environment or adversarial-file-mutation guarantees from this scoped static read. No new generic hardening or diagnostic run was requested or performed.
