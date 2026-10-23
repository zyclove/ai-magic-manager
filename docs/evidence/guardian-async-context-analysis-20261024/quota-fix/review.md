# Quota pages: explicit mounted checks after async gaps

Static author candidate for the r11 diagnostic batch at source commit `abb2e016650cf579fc7ad1dbccdecc682072807a`. Only quota_page.dart and quota_plans_page.dart are proposed; Main is unchanged. Analyzer clearance and all behavior remain UNRUN.

## Cause and minimal correction

QuotaPage.interactive(target) already checks target.mounted plus current page scope and active/current/available route; QuotaPlansPage.onTop(parent) already checks parent.mounted plus current plan scope. The lint cannot infer a mounted check hidden inside those helpers or DialogAccessBinding.permitted(). These BuildContext parameters are used after awaits without a local explicit guard. State.mounted alone would not prove that an independently supplied parent/detail context is mounted.

Exactly seven synchronous `if (!<same context>.mounted) return;` statements are inserted immediately after relevant awaits and before later uses; every original helper/scope/access check follows unchanged:

- quota_page create: after subjects/all (original169) and applications/all (175), covering reported170/172/176/178; details: after pool GET (244), covering245/246. The guards use the actual `context` parameter before helper/toast/form/detail uses.
- quota_plans_page edit: after each conditional subjects/applications read (174/181), covering175/177/182/189/215. The guards use the actual `parent` parameter before toast, Owned route construction/presentation. Existing-plan no-read branches are harmlessly guarded too.
- quota_plans_page details: after GET (228), covering229/233; after awaited scopedDetailsDialog completion (289), covering290/291 before requested edit opens with that same parent. requestedEdit/canWrite/access/onTop logic stays unchanged.

## Ownership and scope preserved

Read both complete pages, ViewLifetime, DeviceSubflowScope, DialogAccessBinding and OwnedDialogRoute, plus relevant ResourcePage caller guards. Lifetime invalidates on deactivate/dispose; scope captures original actor/tenant/role/generation and scoped API; dialog binding retains original parent availability/access; owned finish completes only its own route. No captured_operation helper is imported by these pages or matched by the relevant current-source text search. No helper is introduced.

Only seven ASCII guard lines are added. Removing those exact whole lines reconstructs both before files byte-for-byte. Original scope/permission/route/lifetime checks, listener cleanup, request key/version/path/body, onSubmit/loadCalendar closures and route results are unchanged. No current-route requirement is added to persistent accepted access, preserving valid sent covered-save completion. No ignore, import, dependency, API, feature or test change.

## Limits

Text/hash/diff preparation only; no SDK/analyzer/test/compiler/formatter/AST/parser/candidate-function/predicate/fixture/process/network run. The fifteen reported diagnostics motivate these checks; they are not claimed cleared without the next current-source verification. Other diagnostics/imports are outside this candidate. No Main/Git/old candidate/shared runtime/cache payload was changed.
