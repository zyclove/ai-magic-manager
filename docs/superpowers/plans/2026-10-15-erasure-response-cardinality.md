# Shared response ownership cardinality implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accept the existing 200-device reporting contract with complete response ownership and preserve permanent refusal after a shared cached response is erased.

**Architecture:** Keep the existing Spring JDBC transaction and independent erasure ledger. One ownership bound applies to creation, replay validation and erasure validation. Report ownership is captured from the authorized creation snapshot inside the mutation, never reconstructed from later device relationships.

**Tech Stack:** Java 17, Spring transactions/JDBC, JUnit 5, existing H2 and isolated MySQL fixtures.

**Spec:** Existing `docs/data-erasure-contract.md`, `docs/erasure-idempotency-plan.md` and the production `ReportJobSelection` 200-device contract. This resolves a confirmed inconsistency within the approved 1.0.0 work.

## Global constraints

- Version 1.0.0; no historical upgrade chain or compatibility layer.
- No business database, volume or deployed service mutation in this implementation phase.
- Freeze HEAD `610b0419af5de41292dae3923fb840b6d569d0e3` plus the exact owned overlay for each gate; exclude all peer WIP, especially the shared V1 schema and family features.
- SCOPED ownership contains 1..200 distinct canonical subject UUIDs in one canonical tenant; copies are sorted, deduplicated and immutable.
- Validation reads at most the common maximum plus one row, rejects 201 owners and rolls back the whole transaction; it must not truncate a corrupted set.
- Unknown responses in any tenant or global scope continue to block erasure completion.
- Internal step DONE is not completed public subject erasure. Keep `executionAvailable=false` until the remaining control plane, writers and full data coverage are verified.
- Do not weaken the ordinary API pause after ledger acceptance. Service-level 410 tests do not prove ordinary HTTP 410 during that pause.

## Review focus

- 200 devices can represent 200 distinct subjects or repeated subjects; every real subject must be attributed exactly once.
- Replayed or read-only recovered responses retain their historical ownership without invoking the business mutation or its attribution callback.
- Two subject jobs sharing one response must clear it exactly once, retain all ownership tombstones and resume safely after fencing/lease changes.
- A 201st restored owner must fail before committing any partial redaction or checkpoint.
- Report authorization failure must leave no report job, part, journal, ownership row or operation audit from the failed transaction.

## Owned files

- `backend/src/main/java/com/aimanager/idempotency/ResponseOwnership.java`: common maximum.
- `backend/src/main/java/com/aimanager/idempotency/IdempotencyService.java`: bounded complete ownership validation.
- `backend/src/main/java/com/aimanager/retention/internal/ErasureIdempotencyProcessor.java`: same bound and corruption refusal.
- `backend/src/main/java/com/aimanager/reporting/internal/ReportJobService.java`: creation-snapshot ownership.
- `backend/src/test/java/com/aimanager/idempotency/IdempotencyOwnershipTest.java`: creation/replay/recovery, deduplication and oversized rollback.
- `backend/src/test/java/com/aimanager/UsageReportJobJourneyTest.java`: real endpoint, complete snapshot owners and failed authorization rollback.
- New `backend/src/test/java/com/aimanager/retention/internal/ErasureIdempotencyCardinalityTest.java`: real journal + independent ledger + shared response processor journey.
- This plan and a later exact verification record. Existing documentation describing 100/101 will be updated after behavior is verified.

## Tasks

- [x] Write regression tests; freeze test overlay on the pinned baseline; observe expected cardinality and missing-attribution failures before production edits. Frozen r3 produced 57 tests, 8 expected assertion failures, no errors and one environment-dependent Dart skip.
- [x] Introduce the common bound and complete max+1 reads; attach report owners from the same authorized snapshot; verify targeted H2 results. Frozen green r1 produced 81 tests, 80 passed, no failures/errors and the same Dart skip.
- [ ] Execute shared-response ledger interleaving, restart/fencing and corruption rollback coverage; exercise isolated MySQL without touching deployed databases.
- [ ] Run the complete backend suite against a final immutable source; record every failure/skip and independently review production and tests.
- [ ] Recheck root/frozen/commit bytes and coordinate the shared index before exact commit/push; deployment requires a separately verified full release and fresh backup.

## Remaining full-product work

The remaining unclassified domain writers, production erasure dispatcher/control plane, applied watermark and safe reopening, complete subject/reference/external-copy coverage, and restore/delete acceptance remain required by the full objective. This cardinality repair does not replace those requirements or mark the goal complete.
