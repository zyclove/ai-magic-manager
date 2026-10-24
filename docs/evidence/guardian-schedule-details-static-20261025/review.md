# Independent Schedule details review

Static conclusion: no clear blocker found in the pinned Schedule method and five appended test declarations. No runtime acceptance is claimed.

The method captures a read-permitted DeviceSubflowScope before presentation and binds the existing actionDetails access mechanism to scope, revocation and originating-route changes. Client acquisition and response completion retain scoped API checks. A covering route does not invalidate an accepted read; completion updates only the inline result and does not push or remove another window. Each new check clears the previous result. closeOnSuccess:false keeps the plan open for another check.

Private access failures revoke the merged access binding and hide old plan/result content; REAUTH_REQUIRED remains recoverable. The existing detail component guards its reauthentication callback. Finally sets live=false before disposing scope and notifiers. Both requestCurrent and the failure handler short-circuit before using disposed state. The final nullable route type check is consistent with its OwnedDialogRoute branch. Business response fields and saved schedule schema are unchanged.

The five new literal tests cover inline replacement and repeated checks, actor/role ABA redaction, client-wait cancellation before dispatch, a late response under an independent covering notice, and 403/WORKSPACE_CHANGED versus REAUTH_REQUIRED behavior. The default optional API fixture remains unchanged for existing policy cases. The imported flush helper is bounded; settle also has a timeout. No obvious compile or endless-wait blocker was found by reading.

All five new tests are UNRUN. No direct new test is claimed for non-REAUTH 401 or forced primary-route removal; those branches were inspected statically. Read-only command outputs a41392, ec3311, 443feb and 92e022 exited 0. No SDK, Dart, AST, formatter, fixture, browser, native/process API, HTTP, test or Git write was performed. Only this new review.md and pins.json were written.
