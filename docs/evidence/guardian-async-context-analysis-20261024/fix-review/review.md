# Async-context minimal fix: independent static review

STATIC_NO_BLOCKER. All runtime/analyzer/UI scenarios remain UNRUN after this edit. The retained r11 RED is unchanged; this review does not claim that its19 diagnostics have been cleared by a fresh analyzer.

Read-only Git delta against abb2e016650cf579fc7ad1dbccdecc682072807a and actual Main hashes show exactly seven BuildContext.mounted guard insertions, three State.mounted condition prefixes, and one removed foundation import in the five fixed files. Reconstructing only those declared text edits matches every actual after byte; no other body/payload/key/version/route/scope/control logic differs.

- quota_page.dart: create's actual BuildContext parameter is checked immediately after subjects/apps awaits and before interactive(context), toast/formDialog use; details checks its same parameter after pool GET before interactive/scopedDetailsDialog. Existing try/finally still releases scope/access on early return.
- quota_plans_page.dart: the actual parent BuildContext parameter is checked after subjects/apps preflight, plan GET, and awaited details close before a new edit. The same parent is passed to onTop/toast/owned dialog/edit; owner/access/canWrite/available/current predicates and finally access.dispose are unchanged.
- quota_plan_editor.dart: addOverride uses State.context; the State.mounted prefix immediately follows its owned date-route await, before creating the next form. childPermitted/current/selected-null checks and the finally childAccess release/operation cleanup remain intact.
- audit_view.dart: open checks this State.mounted after repository.detail before actionDetails(State.context); dates checks the same State after showDateRangePicker before toast/setState. Repository/generation/operation/current guards and finally cleanup are preserved.
- view_lifetime.dart: only the redundant foundation import is removed. The existing widgets import remains; ValueNotifier/Listenable and scheduler/lifetime implementation are unchanged.

These guards use the corresponding captured context or owning State; they do not substitute mounted for permission or route ownership. No SDK, tests, AST, candidate/business predicate, native/process API or network was executed. Main/Git/original evidence were not written; only this new cache review/pins were created.
