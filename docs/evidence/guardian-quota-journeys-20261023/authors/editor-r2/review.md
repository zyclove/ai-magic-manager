# QuotaPlanEditor ownership candidate, r2

Status: STATIC_AUTHOR_CANDIDATE_REQUIRES_INDEPENDENT_REVIEW_ALL_SCENARIOS_UNRUN. This is the Editor author's second candidate, not an independent acceptance result. Baseline remains bb93c0b0bacfea622e50828e635aa61d738f342b; before.dart is the original Main source, not r1 after. Root owns any integration and commit. No Main/Git/test/dependency/service write, SDK, analyzer/compiler, formatter, AST/parser, candidate/function/business predicate, test, WinAPI/process query or network execution occurred. Only own static text/byte/hash/JSON/diff metadata operations prepared this directory.

## Narrow r1-to-r2 change

Preserved r1's exact six files unchanged. This r2 directory has exactly six new files: before.dart, after.dart, the complete Main-before-to-r2 patch, this review, pins.json and delivery-pins.json. The r1-to-r2 delta appears below for review; it is not applied or executed. Full artifact and input pins are recorded in pins.json.

1. After the unchanged original override operation/calendar/subject/generation permitted definition and before the first await, create one flow-owned DialogAccessBinding(context, accessChanges: changes, hasAccess: permitted). Its lifetime spans the whole awaited date dialog followed by the optional awaited minute form. The local binding is disposed in finally after those futures finish, before the original operation unlock condition.
2. Date AnimatedBuilder and formDialog now receive only childAccess.changes. A surviving child does not subscribe or resubscribe directly to Editor fields/lifetime notifiers after the parent State is disposed. The child binding alone bridges the original changes source while it lives. This is a minimal lifetime hardening; no external route-removal assumption is presented as an observed production failure.
3. childPermitted combines the original permitted and childAccess.permitted. The binding's hasAccess is the ORIGINAL permitted, which never calls childAccess; there is no recursive hasAccess cycle. New date entry/current action, date result, form authorization/reauth/onSubmit and final merge use childPermitted. Original permitted still fixes mounted/active/notclosed/original-owned-available/access plus exact operation, calendar object, subject and generation. Parent loss/close rejects immediately; a legitimate child covering Editor is not treated as loss. Safe redacted date close remains the captured dateRoute.available/current close, so loss can still be closed without popping a cover.
4. The editor redaction copy now directs an already-submitted operation back to its ORIGINAL workspace to refresh and check the result. It no longer suggests checking the currently selected different workspace's list for that result.

## Preserved original contracts and static limits

All Editor fields, original owner capture, accepted/current split, normal edits, initial-calendar deferral, calendar generations, uncertain pending body, submit key/version ownership and entire save function are byte-identical to r1. The original override permitted function and original finally unlock condition are unchanged. DatePickerDialog retains calendar/input modes and the existing local Navigator/Page bridge; dateCurrent gains the local binding guard without weakening own route.current/available. No API/endpoint/package/test or business limit changed. Seven weekday/seconds, UTC civil date/effective date, override 0-1440 minutes and 60-date limit remain as r1. Valid already-dispatched save completion still uses accepted, not current, to finish only its own Owned<void> even if covered; ordinary fallback still never pops a cover.

The flow binding keeps UI notification ownership until the full child route future returns. It does not require parent route.isCurrent while a legitimate child is open. It does not purport to guarantee arbitrary manually retained private Flutter callbacks after disposal cannot touch a disposed context. Physical rendering, keyboard/back/focus/transition behavior, revocation while child covered, owner disposal plus survivor rebuild, repeated child transitions, exact-body retry and all prior scenarios remain UNRUN. Five existing pure Editor tests stay unchanged and unexecuted; they do not cover the new lifecycle boundaries.

Necessary later scenarios are unchanged from r1 plus: original parent disappears while date or minute form survives; child UI rebuilds and is redacted using its still-live local binding; held date/form/save/reauth entries cannot send or merge into the old owner; safe close affects only the current captured child; both cancellation paths release operation only if the original Editor remains accepted; covered valid original save still completes its own route. These are declarations, not executed fixtures or evidence of passing behavior.

## Exact r1-to-r2 textual delta

```diff
--- r1/after.dart
+++ r2/after.dart
@@ -304,11 +304,14 @@
     bool permitted() => accepted && identical(overrideOperation, operation) &&
         identical(calendar, selectedCalendar) && subject == selectedSubject &&
         calendarGeneration == generation;
+    final childAccess = DialogAccessBinding(context,
+        accessChanges: changes, hasAccess: permitted);
+    bool childPermitted() => permitted() && childAccess.permitted();
     try {
-      if (!permitted() || route?.isCurrent != true) return;
+      if (!childPermitted() || route?.isCurrent != true) return;
       final today = DateTime.parse(selectedCalendar!['currentDate']);
       late final OwnedDialogRoute<DateTime> dateRoute;
-      bool dateCurrent() => permitted() && dateRoute.available &&
+      bool dateCurrent() => childPermitted() && dateRoute.available &&
           dateRoute.isCurrent;
       void closeDate() {
         if (dateRoute.available && dateRoute.isCurrent) dateRoute.finish();
@@ -317,8 +320,8 @@
           context: context,
           barrierDismissible: false,
           builder: (_) => AnimatedBuilder(
-              animation: changes,
-              builder: (_, __) => !permitted()
+              animation: childAccess.changes,
+              builder: (_, __) => !childPermitted()
                   ? AlertDialog(
                       title: const Text('工作空间或权限已变化'),
                       content: const Text('已隐藏原日期选择。请关闭后重新打开当前计划。'),
@@ -344,7 +347,7 @@
                         return false;
                       })));
       final selected = await presentOwnedDialog<DateTime>(context, dateRoute);
-      if (!permitted() || !current || selected == null) return;
+      if (!childPermitted() || !current || selected == null) return;
       final date = DateFormat('yyyy-MM-dd').format(selected);
       final result = await formDialog(context,
           title: '$date 的额度',
@@ -355,23 +358,24 @@
           initial: {
             'minutes': (overrides[date] ?? 3600) ~/ 60
           },
-          accessChanges: changes,
-          hasAccess: permitted,
+          accessChanges: childAccess.changes,
+          hasAccess: childPermitted,
           reauth: () {
-            if (permitted()) owner.reauth?.call();
+            if (childPermitted()) owner.reauth?.call();
           },
           onSubmit: (value) async {
-            if (!permitted()) {
+            if (!childPermitted()) {
               throw const ApiFailure(409, 'WORKSPACE_CHANGED');
             }
             final minutes = value['minutes'] as int;
             if (minutes > 1440) throw const ApiFailure(400, 'QUOTA_LIMIT_INVALID');
             return {'seconds': minutes * 60};
           });
-      if (permitted() && current && result != null) {
+      if (childPermitted() && current && result != null) {
         setState(() => overrides[date] = result['seconds'] as int);
       }
     } finally {
+      childAccess.dispose();
       if (accepted && identical(overrideOperation, operation)) {
         setState(() => overrideOperation = null);
       }
@@ -442,7 +446,7 @@
               },
               child: AlertDialog(
                   title: Text(closed ? '编辑已结束' : '工作空间或权限已变化'),
-                  content: const Text('已隐藏原计划内容。请关闭后在当前工作空间重新打开；已提交的操作请先刷新列表核对结果。'),
+                  content: const Text('已隐藏原计划内容。请关闭后在当前工作空间重新打开；已提交的操作请回到原工作空间刷新列表核对结果。'),
                   actions: [
                     TextButton(onPressed: finish, child: const Text('关闭'))
                   ])));
```
