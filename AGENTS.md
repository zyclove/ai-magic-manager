# Project working agreements

## Project context and skills

- For substantial work, read `docs/project-memory.md`, then open only the relevant specification and source links. `docs/SPEC.md` is the specification entry point.
- Reuse the most relevant existing skills; avoid overlapping workflows and unnecessary skill loading. Project conventions belong here or in linked docs, not in duplicate skills.
- Do not automatically install or modify global skills. Create a new skill only for an actual reusable workflow that existing tools and instructions do not cover.
- Update project memory when stable decisions or module boundaries change; keep secrets, personal data, resource samples, and one-off execution history out of it.

## Efficient implementation and verification

- Follow the user's latest scope. Deliver focused code and design improvements; avoid expanding a small task into a repository-wide audit.
- Read only relevant files. Batch independent reads, limit output, and reuse established findings until related inputs change. Do not repeatedly scan the repository, hash large trees, or inspect other chats without a concrete need.
- Choose the smallest meaningful verification for the change:
  - Documentation, wording, or simple styling: inspect the diff and relevant layout/source; no new automated tests by default.
  - Behavior changes and bug fixes: use the affected existing tests, adding a regression only for a meaningful uncovered failure. Avoid tests that merely repeat implementation details.
  - Authentication, authorization, data integrity, shared contracts, or release changes: check affected integration boundaries. Run broad suites/builds when shared impact, failures, or release requirements justify them.
- After appropriate checks pass, stop testing unless further changes or unresolved failures justify another run. Do not repeat SDK qualification or rebuild unchanged components for reassurance.
- Reuse unchanged source/dependency snapshots and results within their verified scope. For documentation-only commits, update necessary revision bindings instead of copying all sources or regenerating all evidence. Historical results never prove changed behavior passed.
- Keep one concise task record and the necessary execution output. Do not create chains of duplicate manifests, reviews, snapshots, or reviews of reviews. Preserve unique source, relevant failures, and required delivery evidence.
- Check current resources once before heavy work. If blocked, record the reason and defer execution; retry only after a meaningful resource, scheduling, or input change. Do not continuously poll, repeat resource recovery, or lower existing safety gates to obtain a pass.
- Serialize heavy builds/tests on this shared machine. Delegate only separable work that saves time or improves quality; keep coordination within human-authorized scope and avoid repeated unchanged messages.
- Resource limits do not prevent focused implementation or a scoped local commit. Clearly distinguish inspected, passed, failed, and not run. Never claim overall acceptance from static review or a health check.
- Prefer normal path-scoped Git operations. Preserve unrelated changes and staged work; use extra commit machinery only when an actual shared-index risk requires it. Commit a completed phase without automatically pushing or deploying.
- Give short updates when findings or blockers change. Final reports should state the change, relevant verification or deferral, and commit; omit repetitive execution history.

## Build and temporary directory hygiene

- Never create task, build, test, source-copy, or temporary directories directly under a drive root (for example E:\yj261016r6 or E:\yj261016-ledger), unless the human explicitly requests that exact location.
- For Windows short-path builds, use E:\tmp\cx\<short-task-id>\ with separate src, out, and tmp children. Otherwise prefer the repository's ignored .cache directory. Keep TEMP/TMP and java.io.tmpdir overrides local to the process; do not change machine or user environment variables for a task.
- Inventory and hash important source snapshots, unique files, screenshots, and delivery evidence before cleaning scratch directories. Keep final deliverables in the project's documented artifact directory. Never delete unique user files, active task directories, or link targets.
- Clean task-owned disposable scratch directories after use when authorized. If deletion requires explicit approval, identify the exact directories and ask for it; do not silently leave scattered root directories.
- Before recursive cleanup, verify resolved paths are inside the exact task directory and unlink directory symlinks without traversing their targets. Preserve audit receipts outside the scratch directory.
- Historical documents mentioning E:\yj* are records of past runs, not instructions to reuse those locations. New plans must follow this policy.
- Do not stop services, rebuild containers, clear caches, or alter shared processes merely to accelerate validation. Check identity, data mounts, and existing authorization before maintenance.
