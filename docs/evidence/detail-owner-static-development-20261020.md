# Detail action ownership: static development checkpoint

Date: 2026-10-20 (Asia/Shanghai)

Status: **NOT_RUN**. This checkpoint records source changes and static inspection only. No Flutter/Dart SDK, test, formatter, analyzer, build, service update, database operation, or credential access was performed for this change. Runtime correctness and regression acceptance remain unproven.

## Confirmed source defect

The three pages contained seven explicit detail-action completion sites that used `Navigator.pop(dialog)` after an asynchronous action, or to leave the detail before starting a follow-up editor. Navigation by the current stack could close an independently presented covering route and leave the original action dialog pending.

The shared `captureDialogCompletion(BuildContext)` helper is supplied separately in `ui/design.dart`. Each changed action captures that helper before its first `await` and invokes the captured callback after its original success condition. The helper finishes the captured `OwnedDialogRoute<void>` rather than the current stack top.

| Page | Changed completion paths | Preserved follow-up behavior |
| --- | --- | --- |
| `classes_page.dart` | Transfer student; remove student | Existing transfer confirmation/result condition and class-detail refresh |
| `members_page.dart` | Cancel invitation; start permission editor; revoke member access | Existing editor refetch, version/idempotency handling, success notices and history viewer |
| `ownership_page.dart` | Propose transfer; shared accept/decline/cancel action implementation | Created-transfer detail, response-state notice and successful permission refresh |

All existing `closeOnSuccess: false` choices remain. The history viewer's synchronous `关闭记录` button is outside detail-action completion and was not changed.

## Ownership journey scope

- `propose` and `open` capture `DeviceSubflowScope` before their first asynchronous read and dispose it with `try/finally`.
- Scope eligibility includes the original mounted context and workspace root. The existing scope implementation captures authentication generation, actor, tenant and role, observes session notifications synchronously, and permanently rejects an away-and-back change.
- Proposal reads and writes use `scope.api`; the original role must remain `OWNER`.
- The recipient-selection form receives `accessChanges: scope` and `hasAccess: () => scope.current`, with an additional submission check. Both detail dialogs receive the same access binding.
- Detail reads and writes use `scope.api`. `accept`/`decline` additionally require the captured actor to be the transfer target; `cancel` requires the captured source actor and `OWNER`. The action-specific guard is also supplied to the actual API dispatch, preserving checks across authentication/client awaits and response delivery.
- A successful action still calls `s.loadTenants()`. The old scope is deliberately not required to survive its own successful handover and permission refresh.

## Source hashes

SHA-256 values are the actual unformatted bytes read after editing.

| Source | Before | After |
| --- | --- | --- |
| `apps/guardian/lib/pages/classes_page.dart` | `accdd9ef31bcd1091a811ac293d3a11adb75aa133c53a60cd4fbc8e584b4a29f` | `f2b53e8663d9e902d2ed6d26419a742294fce828701eedf34a58acfefb9ead22` |
| `apps/guardian/lib/pages/ownership_page.dart` | `5397d28166fb76ab5685a3f45563d0d42316f10d376f27ab8d62eecf5b77eafb` | `72b66d34f2ca5d031159ea975adeb45928e744e2b3c1028d195ffefe1c1d195a` |
| `apps/guardian/lib/pages/members_page.dart` | `081200ebc6a7532d9785f49165136b79654e32c4e6194a94803d0c1fbb3ae728` | `385f32b0c1f63730502b925f71d3a6d32c03139994c6bce0891cd4ad5f26e7b0` |

## Static checks and remaining validation

The edited files were reread in full or with complete changed-action context. Text searches confirmed no `Navigator.pop` remains in `classes_page.dart` or `ownership_page.dart`; the only remaining occurrence in `members_page.dart` is the history viewer button. Both ownership scopes have a matching `finally` disposal. Child-flow API calls are scoped; the page's normal resource-list API is unchanged.

Still required when resources permit: format/analyze; independent source review; covering-route completion and follow-up behavior; canceled confirmations; session/actor/tenant/role changes including away-and-back; action-specific permissions; and successful handover with `loadTenants` updating the operator role. This document is not a test-pass or release record.
