import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../core/api.dart';
import '../ui/design.dart';
import '../ui/dialog_access.dart';
import '../ui/owned_dialog_route.dart';
import '../ui/quota_balance.dart';
import '../ui/view_lifetime.dart';

const quotaWeek = <String, String>{
  'MONDAY': '周一',
  'TUESDAY': '周二',
  'WEDNESDAY': '周三',
  'THURSDAY': '周四',
  'FRIDAY': '周五',
  'SATURDAY': '周六',
  'SUNDAY': '周日'
};

/// Pure form: the caller supplies fixed workspace, version and idempotency context.
class QuotaPlanEditor extends StatefulWidget {
  final Map<String, String> children, applications;
  final Json? plan;
  final String? targetDescription;
  final Future<Json> Function(String subject) loadCalendar;
  final Future<void> Function(Json body) onSubmit;
  final VoidCallback? reauth;
  final Listenable? accessChanges;
  final bool Function()? hasAccess;
  const QuotaPlanEditor(
      {super.key,
      required this.children,
      required this.applications,
      this.plan,
      this.targetDescription,
      required this.loadCalendar,
      required this.onSubmit,
      this.reauth,
      this.accessChanges,
      this.hasAccess});
  @override
  State<QuotaPlanEditor> createState() => _QuotaPlanEditorState();
}

class _QuotaPlanEditorState extends State<QuotaPlanEditor> {
  late final QuotaPlanEditor owner;
  final lifetime = ViewLifetime();
  DialogAccessBinding? access;
  ModalRoute<dynamic>? route;
  late final Listenable changes;
  bool active = true, closed = false, bound = false;
  Object? overrideOperation, saveOperation;
  final form = GlobalKey<FormState>();
  final errorAnchor = GlobalKey();
  late final TextEditingController name;
  final days = <String, TextEditingController>{};
  final originalSeconds = <String, int>{};
  final changedDays = <String>{};
  final overrides = <String, int>{};
  String? subject;
  String application = '', state = 'ACTIVE';
  bool tomorrow = false, busy = false;
  int calendarGeneration = 0;
  Json? calendar, pending;
  Object? error;
  bool get locked => busy || pending != null || overrideOperation != null;
  bool get editing => owner.plan != null;
  bool get accepted {
    if (!mounted || !active || closed || !lifetime.active || !bound) return false;
    final original = route;
    final allowed = original != null && original.isActive &&
        (original is! OwnedDialogRoute<dynamic> || original.available) &&
        access?.permitted() == true;
    if (!allowed) invalidate();
    return allowed;
  }
  bool get current => accepted && route?.isCurrent == true;
  bool get canAct => current && !busy && overrideOperation == null;
  bool get canEdit => canAct && pending == null;

  void invalidate() {
    calendarGeneration++;
    overrideOperation = null;
    saveOperation = null;
    lifetime.invalidate();
  }

  void observeAccess() {
    if (bound && lifetime.active) {
      // accepted invalidates synchronously; notification is deferred by lifetime.
      if (!accepted) lifetime.invalidate();
    }
  }

  void markClosed() {
    closed = true;
    invalidate();
  }

  void finish({bool allowCovered = false}) {
    if (!mounted || !active) return;
    final original = route;
    if (original == null || !original.isActive ||
        (!allowCovered && !original.isCurrent)) return;
    if (original is OwnedDialogRoute<void>) {
      if (!original.available) return;
      markClosed();
      original.finish();
    } else {
      markClosed();
      if (original.isCurrent) original.navigator?.pop<void>();
    }
  }

  void cancel() {
    if (!canAct) return;
    finish();
  }

  void reauthenticate() {
    if (!canAct) return;
    owner.reauth?.call();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final original = ModalRoute.of(context);
    if (bound) {
      if (!identical(route, original)) invalidate();
      return;
    }
    route = original;
    access = DialogAccessBinding(context,
        accessChanges: owner.accessChanges,
        hasAccess: () => lifetime.active && !closed &&
            owner.hasAccess?.call() != false);
    changes = Listenable.merge([lifetime.changes, access!.changes]);
    bound = true;
    access!.changes.addListener(observeAccess);
    owner.accessChanges?.addListener(observeAccess);
    observeAccess();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (accepted && subject != null) readCalendar();
    });
  }

  @override
  void deactivate() {
    active = false;
    invalidate();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    active = true;
  }
  @override
  void initState() {
    super.initState();
    owner = widget;
    final p = owner.plan;
    name = TextEditingController(text: p?['name'] as String? ?? '每周使用额度');
    subject = p?['subjectId'] as String? ??
        (owner.children.length == 1 ? owner.children.keys.first : null);
    application = p?['applicationId'] as String? ?? '';
    state = p?['state'] as String? ?? 'ACTIVE';
    for (final day in quotaWeek.keys) {
      final seconds =
          ((p?['weeklyLimits'] as Map?)?[day] as num?)?.toInt() ?? 3600;
      originalSeconds[day] = seconds;
      days[day] = TextEditingController(text: (seconds ~/ 60).toString());
    }
    for (final entry in ((p?['dateOverrides'] as Map?) ?? {}).entries) {
      overrides[entry.key as String] = (entry.value as num).toInt();
    }
  }

  Future<void> loadCalendar() async {
    if (!canEdit) return;
    await readCalendar();
  }

  Future<void> readCalendar() async {
    if (!accepted || locked) return;
    final selected = subject;
    if (selected == null) return;
    final generation = ++calendarGeneration;
    setState(() {
      calendar = null;
      error = null;
    });
    try {
      final value = await owner.loadCalendar(selected);
      if (accepted && generation == calendarGeneration && subject == selected) {
        setState(() => calendar = value);
      }
    } catch (e) {
      if (accepted && generation == calendarGeneration && subject == selected) {
        setState(() => error = e);
        revealError();
      }
    }
  }

  void revealError() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = errorAnchor.currentContext;
      if (current && target != null) {
        Scrollable.ensureVisible(target,
            alignment: 1,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut);
      }
    });
  }

  String get effectiveDate {
    final today = calendar?['currentDate'] as String?;
    if (today == null) return '读取日历中';
    final date = DateTime.parse(today);
    // Civil dates must not inherit the browser's 23/25-hour DST day.
    return DateFormat('yyyy-MM-dd').format(DateTime.utc(
        date.year, date.month, date.day + (editing || tomorrow ? 1 : 0)));
  }

  @override
  void dispose() {
    active = false;
    markClosed();
    owner.accessChanges?.removeListener(observeAccess);
    final binding = access;
    binding?.changes.removeListener(observeAccess);
    lifetime.dispose();
    // Descendant forms first observe lifetime loss, then release this binding.
    WidgetsBinding.instance.addPostFrameCallback((_) => binding?.dispose());
    WidgetsBinding.instance.ensureVisualUpdate();
    name.dispose();
    for (final c in days.values) {
      c.dispose();
    }
    super.dispose();
  }

  void copyDays(String source, Iterable<String> targets) {
    if (!canEdit || !days.containsKey(source)) return;
    final selected = targets.toList(growable: false);
    if (selected.any((day) => !days.containsKey(day))) return;
    for (final day in selected) {
      days[day]!.text = days[source]!.text;
      changedDays.add(day);
    }
    setState(() {});
  }

  void changeSubject(String? value) {
    if (!canEdit || editing ||
        (value != null && !owner.children.containsKey(value))) return;
    setState(() {
      subject = value;
      calendarGeneration++;
      calendar = null;
      error = null;
    });
    loadCalendar();
  }

  void changeApplication(String? value) {
    if (!canEdit || editing || (value != null && value.isNotEmpty &&
        !owner.applications.containsKey(value))) return;
    setState(() => application = value ?? '');
  }

  void changeTomorrow(bool? value) {
    if (!canEdit || editing) return;
    setState(() => tomorrow = value ?? false);
  }

  void changePlanState(String? value) {
    if (!canEdit || !editing ||
        (value != 'ACTIVE' && value != 'PAUSED')) return;
    setState(() => state = value!);
  }

  void removeOverride(String date) {
    if (!canEdit || !overrides.containsKey(date)) return;
    setState(() => overrides.remove(date));
  }

  Future<void> addOverride() async {
    if (!canEdit || calendar == null) return;
    if (overrides.length >= 60) {
      toast(context, '最多设置 60 个日期例外，请先删除不再需要的日期。');
      return;
    }
    final operation = Object();
    final selectedCalendar = calendar;
    final selectedSubject = subject;
    final generation = calendarGeneration;
    setState(() => overrideOperation = operation);
    bool permitted() => accepted && identical(overrideOperation, operation) &&
        identical(calendar, selectedCalendar) && subject == selectedSubject &&
        calendarGeneration == generation;
    final childAccess = DialogAccessBinding(context,
        accessChanges: changes, hasAccess: permitted);
    bool childPermitted() => permitted() && childAccess.permitted();
    try {
      if (!childPermitted() || route?.isCurrent != true) return;
      final today = DateTime.parse(selectedCalendar!['currentDate']);
      late final OwnedDialogRoute<DateTime> dateRoute;
      bool dateCurrent() => childPermitted() && dateRoute.available &&
          dateRoute.isCurrent;
      void closeDate() {
        if (dateRoute.available && dateRoute.isCurrent) dateRoute.finish();
      }
      dateRoute = OwnedDialogRoute<DateTime>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AnimatedBuilder(
              animation: childAccess.changes,
              builder: (_, __) => !childPermitted()
                  ? AlertDialog(
                      title: const Text('工作空间或权限已变化'),
                      content: const Text('已隐藏原日期选择。请关闭后重新打开当前计划。'),
                      actions: [
                        TextButton(onPressed: closeDate, child: const Text('关闭'))
                      ])
                  : Navigator(
                      pages: [
                        MaterialPage<DateTime>(
                            child: DatePickerDialog(
                                initialDate: today,
                                firstDate: today,
                                lastDate: DateTime(
                                    today.year, today.month, today.day + 366),
                                helpText: '选择单独设置额度的日期'))
                      ],
                      // The stock picker pops its nearest navigator. Keep that
                      // pop local, and complete only its captured owned dialog.
                      onPopPage: (_, result) {
                        if (dateCurrent()) {
                          dateRoute.finish(result is DateTime ? result : null);
                        }
                        return false;
                      })));
      final selected = await presentOwnedDialog<DateTime>(context, dateRoute);
      if (!mounted || !childPermitted() || !current || selected == null) return;
      final date = DateFormat('yyyy-MM-dd').format(selected);
      final result = await formDialog(context,
          title: '$date 的额度',
          description: '此日期使用这里的额度，覆盖星期规则。0 分钟表示该日无可分配时间。',
          fields: const [
            FieldSpec('minutes', '额度（分钟，0–1440）', numeric: true, maxLength: 4)
          ],
          initial: {
            'minutes': (overrides[date] ?? 3600) ~/ 60
          },
          accessChanges: childAccess.changes,
          hasAccess: childPermitted,
          reauth: () {
            if (childPermitted()) owner.reauth?.call();
          },
          onSubmit: (value) async {
            if (!childPermitted()) {
              throw const ApiFailure(409, 'WORKSPACE_CHANGED');
            }
            final minutes = value['minutes'] as int;
            if (minutes > 1440) throw const ApiFailure(400, 'QUOTA_LIMIT_INVALID');
            return {'seconds': minutes * 60};
          });
      if (childPermitted() && current && result != null) {
        setState(() => overrides[date] = result['seconds'] as int);
      }
    } finally {
      childAccess.dispose();
      if (accepted && identical(overrideOperation, operation)) {
        setState(() => overrideOperation = null);
      }
    }
  }

  Future<void> save() async {
    if (!canAct) return;
    if (form.currentState?.validate() != true || calendar == null || subject == null) {
      return;
    }
    final data = pending ??
        <String, dynamic>{
          'name': name.text.trim(),
          if (editing) 'state': state,
          if (!editing) ...{
            'subjectId': subject,
            'scope': application.isEmpty ? 'TOTAL' : 'APPLICATION',
            if (application.isNotEmpty) 'applicationId': application,
            'timeZone': calendar!['timeZone'],
            'effectiveFrom': effectiveDate,
          },
          'weeklyLimits': {
            for (final day in quotaWeek.keys)
              day: changedDays.contains(day)
                  ? int.parse(days[day]!.text) * 60
                  : originalSeconds[day]
          },
          'dateOverrides': Map<String, int>.from(overrides),
        };
    final operation = Object();
    saveOperation = operation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await owner.onSubmit(data);
      if (accepted && identical(saveOperation, operation)) {
        finish(allowCovered: true);
      }
    } catch (e) {
      if (accepted && identical(saveOperation, operation)) {
        setState(() {
          error = e;
          if (e is! ApiFailure || e.status == 0 || e.status >= 500) {
            pending = data;
          }
        });
        revealError();
      }
    } finally {
      if (accepted && identical(saveOperation, operation)) {
        saveOperation = null;
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: changes,
      builder: (_, __) => accepted
          ? editor(context)
          : PopScope(
              onPopInvoked: (didPop) {
                if (didPop) markClosed();
              },
              child: AlertDialog(
                  title: Text(closed ? '编辑已结束' : '工作空间或权限已变化'),
                  content: const Text('已隐藏原计划内容。请关闭后在当前工作空间重新打开；已提交的操作请回到原工作空间刷新列表核对结果。'),
                  actions: [
                    TextButton(onPressed: finish, child: const Text('关闭'))
                  ])));

  Widget editor(BuildContext context) {
    final generation = calendarGeneration;
    final selected = subject;
    return PopScope(
      canPop: !busy,
      onPopInvoked: (didPop) {
        if (didPop) markClosed();
      },
      child: AlertDialog(
        title: Text(editing ? '修改重复计划' : '创建重复计划'),
        content: SizedBox(
            width: 680,
            child: SingleChildScrollView(
                child: Form(
                    key: form,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (editing && owner.targetDescription != null)
                            Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Text(owner.targetDescription!,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        height: 1.6))),
                          Notice(editing
                              ? '修改从下方生效日开始；今天的余额、已用量和预留保持原样。'
                              : '每天自动生成一份额度。已有的每日额度保留，计划不会覆盖当天手工调整。'),
                          const SizedBox(height: 20),
                          TextFormField(
                              controller: name,
                              enabled: canEdit,
                              decoration:
                                  const InputDecoration(labelText: '计划名称'),
                              maxLength: 100,
                              validator: (v) =>
                                  (v ?? '').trim().isEmpty ? '请输入计划名称' : null),
                          if (!editing) ...[
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                                value: subject,
                                isExpanded: true,
                                decoration:
                                    const InputDecoration(labelText: '儿童'),
                                items: [
                                  for (final child in owner.children.entries)
                                    DropdownMenuItem(
                                        value: child.key,
                                        child: Text(child.value,
                                            overflow: TextOverflow.ellipsis))
                                ],
                                onChanged: !canEdit
                                    ? null
                                    : changeSubject,
                                validator: (v) => v == null ? '请选择儿童' : null),
                            const SizedBox(height: 18),
                            DropdownButtonFormField<String>(
                                value: application,
                                isExpanded: true,
                                decoration:
                                    const InputDecoration(labelText: '额度范围'),
                                items: [
                                  const DropdownMenuItem(
                                      value: '', child: Text('儿童总额度')),
                                  ...owner.applications.entries.map((e) =>
                                      DropdownMenuItem(
                                          value: e.key,
                                          child: Text(e.value,
                                              overflow: TextOverflow.ellipsis)))
                                ],
                                onChanged: !canEdit
                                    ? null
                                    : changeApplication),
                            CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('从明天开始'),
                                value: tomorrow,
                                onChanged: !canEdit
                                    ? null
                                    : changeTomorrow),
                          ],
                          const SizedBox(height: 12),
                          Text(
                              '生效日：$effectiveDate  ·  时区：${calendar?['timeZone'] ?? '等待选择儿童'}',
                              style:
                                  const TextStyle(color: muted, height: 1.6)),
                          const SizedBox(height: 20),
                          const Text('每周额度',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 16)),
                          const SizedBox(height: 8),
                          const Text('0 表示无可分配时间；修改需要近期多因素认证。',
                              style: TextStyle(color: muted, fontSize: 12)),
                          Wrap(spacing: 8, children: [
                            TextButton(
                                onPressed: !canEdit
                                    ? null
                                    : () => copyDays(
                                        'MONDAY', quotaWeek.keys.take(5)),
                                child: const Text('周一额度应用到工作日')),
                            TextButton(
                                onPressed: !canEdit
                                    ? null
                                    : () => copyDays(
                                        'SATURDAY', ['SATURDAY', 'SUNDAY']),
                                child: const Text('周六额度应用到周末')),
                          ]),
                          LayoutBuilder(
                              builder: (context, size) =>
                                  Wrap(spacing: 16, runSpacing: 16, children: [
                                    for (final day in quotaWeek.entries)
                                      SizedBox(
                                          width: size.maxWidth > 480
                                              ? (size.maxWidth - 16) / 2
                                              : size.maxWidth,
                                          child: TextFormField(
                                              controller: days[day.key],
                                              enabled: canEdit,
                                              keyboardType:
                                                  TextInputType.number,
                                              inputFormatters: [
                                                FilteringTextInputFormatter
                                                    .digitsOnly
                                              ],
                                              maxLength: 4,
                                              decoration: InputDecoration(
                                                  labelText: '${day.value}（分钟）',
                                                  helperText: originalSeconds[
                                                                  day.key]! %
                                                              60 !=
                                                          0
                                                      ? '原额度 ${quotaDuration(originalSeconds[day.key])}，不改此项会保留秒数'
                                                      : null),
                                              onChanged: (_) {
                                                if (!canEdit) return;
                                                changedDays.add(day.key);
                                              },
                                              validator: (v) {
                                                final n = int.tryParse(v ?? '');
                                                return n == null ||
                                                        n < 0 ||
                                                        n > 1440
                                                    ? '请输入 0–1440 分钟'
                                                    : null;
                                              })),
                                  ])),
                          const SizedBox(height: 20),
                          Row(children: [
                            const Expanded(
                                child: Text('日期例外',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 16))),
                            TextButton.icon(
                                onPressed: !canEdit || calendar == null
                                    ? null
                                    : addOverride,
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('添加日期'))
                          ]),
                          if (overrides.isEmpty)
                            const Text('暂无例外，所有日期按星期规则生成。',
                                style: TextStyle(color: muted)),
                          for (final date in (overrides.keys.toList()..sort()))
                            ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(date),
                                subtitle: Text(quotaDuration(overrides[date])),
                                trailing: IconButton(
                                    tooltip: '删除 $date 的例外',
                                    onPressed: !canEdit
                                        ? null
                                        : () => removeOverride(date),
                                    icon: const Icon(Icons.close, size: 18))),
                          if (editing) ...[
                            const SizedBox(height: 20),
                            DropdownButtonFormField<String>(
                                value: state,
                                isExpanded: true,
                                decoration:
                                    const InputDecoration(labelText: '生效日之后'),
                                items: const [
                                  DropdownMenuItem(
                                      value: 'ACTIVE', child: Text('每天自动生成额度')),
                                  DropdownMenuItem(
                                      value: 'PAUSED', child: Text('暂停后续日期的生成'))
                                ],
                                onChanged: !canEdit
                                    ? null
                                    : changePlanState)
                          ],
                          if (pending != null) ...[
                            const SizedBox(height: 16),
                            const Notice('上次提交结果尚未确认。输入已保留，重试将发送完全相同的内容。',
                                warning: true)
                          ],
                          if (error != null) ...[
                            Padding(
                                key: errorAnchor,
                                padding: const EdgeInsets.only(top: 16),
                                child: FailureView(error!,
                                    reauth: owner.reauth == null
                                        ? null : reauthenticate,
                                    retry:
                                        calendar == null ? () {
                                          if (!canEdit || subject != selected ||
                                              generation != calendarGeneration) return;
                                          loadCalendar();
                                        } : null))
                          ],
                        ])))),
        actions: [
          TextButton(
              onPressed: canAct ? cancel : null,
              child: const Text('取消')),
          FilledButton(
              onPressed: !canAct || calendar == null ? null : save,
              child: Text(busy
                  ? '保存中…'
                  : pending != null
                      ? '重试原提交'
                      : '保存计划'))
        ],
      ));
  }
}
