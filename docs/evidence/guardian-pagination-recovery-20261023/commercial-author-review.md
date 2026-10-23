# Commercial list recovery candidate r1

Status: **STATIC_CANDIDATE_UNRUN_NOT_APPLIED**. Implements only P2-1 from the separately authored `.cache/guardian-pagination-variant-static-20261023-r1/review.md`. Two production files are proposed: commercial catalog and contracts pages. Main and Git remain unwritten. No SDK, test, formatter, build, code parser, candidate import/execution, network or WinAPI call was performed; no rendered behavior was observed.

## Change

Both pages now maintain `listPageFailed`, the explicit mode of the currently displayed list failure. Every list request start and successful list response clears `listError` and that mode; a current failure records `more`. A scope-denied reset clears the mode while retaining the original denied error and current checks.

FailureView now calls `retryList`. The action rechecks mounted/current, a presently non-null list error and both loading flags before using the current failure mode. A captured retry after success or during another request does nothing. Append failure retry uses the retained next cursor and accumulated rows; an initial or explicit-refresh failure uses the first page even when older rows remain visible. No failure-mode inference from row count was introduced.

Append requests reject while either first-page or append loading is active, and the load-more control is disabled for both states. Fresh requests retain their original ability to supersede an in-flight append: there is no global loadingMore guard on the fresh entry; it still increments listGeneration and now synchronously clears loadingMore. The original generation/list-ticket checks prevent the superseded append's success or catch from changing the new list state. This preserves explicit refresh and the existing fresh reloads after successful writes.

Current actor/tenant/role checks, repository calls, duplicate-response checks, selection/detail/history/comparison logic, write operations, versions and idempotency keys are unchanged. There are no new dependencies, tests, APIs, cursors, timeouts, selectors or execution components. This candidate does not implement P2-2 in help requests.

## Static scenario trace — all UNRUN

1. Accumulated pages -> append fails -> retryList reads `more=true`, keeps rows and cursor, starts the same page, then success clears the obsolete error.
2. Accumulated pages -> explicit fresh request fails -> retryList reads `more=false`, preserving the intended fresh-page retry despite nonempty old rows.
3. Append succeeds after a prior failure -> old retry callback sees no error and sends no additional first-page read.
4. Two immediate retry callbacks -> the first synchronously clears the error/sets loading; the second is rejected.
5. Append pending -> explicit or write-triggered fresh request -> listGeneration advances, loadingMore clears, fresh request is sent; the old append's response/catch is rejected.
6. Fresh request pending -> held or normal load-more action -> loader guard and UI disable prevent an append using the earlier cursor.
7. Permission loss, disposal or another active list request -> retryList rejects before requesting data. Existing late-response generation/current checks remain.

These are source traces, not successful runtime checks. Compilation, network scheduling, existing tests and rendering remain **UNRUN**. Root and a separate reviewer must review the exact sealed before/after patch before application or later separately authorized validation.

Before SHA256: catalog `8707f8c041af44e6c790c1d31f7ea1cdaf41ad014152641ea9eb107f427ae12f`; contracts `6d32ef2b41d73000333a02d9f1fc87bd46f206ddf773c27ba3a1b9d83b0fd898`.

After SHA256: catalog `6e948a6881e68838eaf838917259a663849fb66107a3037ca093c89444e45819`; contracts `4737b6672e373e0e08d90ff00373725b14faaac8f8529964bfe48546e1ca258c`.
