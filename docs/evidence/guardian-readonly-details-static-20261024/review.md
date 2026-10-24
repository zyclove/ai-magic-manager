# Independent read-only details review

Conclusion: no clear blocking regression found by static reading of the two production diffs and final test diff. This is not runtime acceptance.

`ResourcePage.refreshAfterOpen` defaults to true. The resource factory forwards it, and only the immutable schedules list opts out. The open callback captures this option; existing owner, current-view, callback identity and action-lock checks remain unchanged. Create still uses the default refresh path. The read-only return skips only `load()`, retaining loaded pages, search and cursor. Existing mutable-details refresh behavior remains the default.

Schedule exception display maps each existing start/end pair to readable hours and joins with a separator; an empty window list still says all-day closed. This changes display text only, without altering API or business schema.

The test host forwards the new option, defaulting to true. Two appended cases assert retained multi-page rows/search/next cursor without an extra GET, duplicate-open locking and reopening after close, and no implicit refresh after network loss. The existing successful-detail refresh regression remains unchanged. No obvious compile or unbounded-wait blocker was identified from the final diff. Both new cases are UNRUN; existing test execution status is unchanged.

Review commands f69894, 1295f5 and fdd493 exited 0. This review used only source reads and read-only Git diff; no SDK, Dart, formatter, AST, fixture, browser, native/process API, HTTP, tests or Git writes were performed. Only the two files in this new review directory were written.
