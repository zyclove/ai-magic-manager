# ResourcePage: separate event interaction from accepted read ownership

The optional canInteract predicate gates new component-generated user events and the clearSearch/action entry points. build captures the original predicate with owner generation, API, path and original handlers. Each held UI callback checks it again before control, focus, load/action or authentication work. The original handler identity, loading/acting and pagination checks are preserved. The text field and create/open controls use the combined gate in their existing enabled conditions.

Persistent isCurrent continues to describe owner validity. load() and the internal completion/refresh of an action that was already accepted do not reference canInteract. Consequently covering a legitimate dialog does not revoke its API scope or discard an accepted result. Original-owner revocation still rejects those results. Omitted canInteract preserves existing behavior. The hook can become false while covered and true on return; this is distinct from sticky scope revocation.

External toolbar and ColumnSpec controls remain the host's responsibility. Some controls behind a cover retain their existing visual enabled state but their guarded callbacks reject new events; this is not a claim that every covered control is visually disabled. This patch adds no tests or dependencies and changes no business API. Complete before/after and all eight patch hunks were manually read. Compilation, interaction, accessibility and the full existing/new scenario scope remain UNRUN.

Status: STATIC_CANDIDATE_UNRUN_REQUIRES_COORDINATED_INTEGRATION. No SDK, tests, formatter, AST/parser, candidate/business predicate, process control or network was executed. Main and Git were not modified.
