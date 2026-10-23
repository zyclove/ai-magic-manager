# ViewLifetime: immediate ownership loss, deferred presentation

This is a new small Flutter lifecycle helper, not a new routing framework. invalidate() immediately sets active=false, and a single post-frame callback publishes the loss to detached dialogs. dispose() is idempotent, calls invalidate first, and schedules notifier disposal after that notification. The disposed flag is set by the final callback, so requesting disposal cannot suppress the earlier notification. ensureVisualUpdate requests a frame for both phases.

Callers must read active synchronously for access and use changes only for presentation. They must capture the original helper and stable merged listenables. A disposed or deactivated owner never reactivates. No HTTP request already sent is claimed canceled by invalidation. Existing DeviceSubflowScope still owns actor/tenant/role/generation; this helper supplies the missing page lifetime notification after that scope is disposed.

The complete 1068-byte source was manually read; the separate shared-contract reviewer inspected these same bytes. The final page/editor callers require their own independent review. Ordinary cover must not invalidate lifetime or accepted completion. Timing, Flutter listener teardown and actual rendering remain UNRUN.

Status: STATIC_CANDIDATE_UNRUN_REQUIRES_COORDINATED_INTEGRATION. No SDK, tests, formatter, AST/parser, candidate/business predicate, process control or network was executed. Main and Git were not modified.
