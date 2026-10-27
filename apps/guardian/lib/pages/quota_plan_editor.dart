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
  /// Read the original result without sending the write again.
  final Future<void> Function(Json body) onRecoverUnknown;
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
      required this.onRecoverUnknown,
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
  final preservedSeconds = <String, int>{};
  final changedDays = <String>{};
  final overrides = <String, int>{};
  String? subject;
  String application = '', state = 'ACTIVE';
  bool tomorrow = false, busy = false;
  int calendarGeneration = 0;
  Json? calendar, pending;
  Object? error, recoveryFailure;
  Object? closeConfirmation;
  bool get confirmingUnknownClose => closeConfirmation != null;
  bool get recoveryStopped => recoveryFailure != null;
  bool get locked => busy || pending != null || recoveryStopped || overrideOperation != null;
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
  bool get canEdit => canAct && pending == null && !recoveryStopped;

  bool privateFailure(Object failure) => failure is ApiFailure &&
      (failure.code == 'WORKSPACE_CHANGED' || failure.status == 403 ||
          (failure.status == 401 && failure.code != 'REAUTH_REQUIRED'));

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
    if (pending != null && !recoveryStopped) {
      if (!confirmingUnknownClose) {
        setState(() => closeConfirmation = Object());
      }
      return;
    }
    finish();
  }

  void keepUnknown(Object confirmation) {
    if (canAct && identical(closeConfirmation, confirmation)) {
      setState(() => closeConfirmation = null);
    }
  }

  void closeUnknown(Object confirmation) {
    if (canAct && identical(closeConfirmation, confirmation) &&
        pending != null && !recoveryStopped) {
      finish();
    }
  }

  void reauthenticate() {
    if (!canAct || confirmingUnknownClose) return;
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
  void didUpdateWidget(covariant QuotaPlanEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.accessChanges, owner.accessChanges) ||
        widget.plan?['id'] != owner.plan?['id'] ||
        widget.plan?['version'] != owner.plan?['version']) {
      invalidate();
    }
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
      preservedSeconds[day] = seconds;
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
        if (privateFailure(e)) {
          invalidate();
          return;
        }
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
    final minutes = int.tryParse(days[source]!.text);
    if (minutes == null || minutes < 0 || minutes > 1440) {
      toast(context, '请先为${quotaWeek[source]}填写 0–1440 分钟。');
      return;
    }
    final seconds = changedDays.contains(source)
        ? minutes * 60 : preservedSeconds[source]!;
    for (final day in selected) {
      days[day]!.text = days[source]!.text;
      preservedSeconds[day] = seconds;
      changedDays.remove(day);
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

  Future<void> editOverride([String? existingDate]) async {
    if (!canEdit || calendar == null) return;
    if (existingDate != null && !overrides.containsKey(existingDate)) return;
    if (existingDate == null && overrides.length >= 60) {
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
      String? chosenDate = existingDate;
      if (chosenDate == null) {
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
        chosenDate = DateFormat('yyyy-MM-dd').format(selected);
      }
      final date = chosenDate;
      final originalLimitSeconds = overrides[date] ?? 3600;
      final result = await formDialog(context,
          title: '$date 的额度',
          description: '此日期额度覆盖星期规则，合计 0 表示计划不分配时间。'
              '这里只修改草稿，最终保存计划后按生效日处理，已生成的每日额度保持原样。',
          submit: '应用到草稿',
          canCommit: false,
          fields: const [
            FieldSpec('minutes', '分钟', numeric: true, maxLength: 4,
                minValue: 0, maxValue: 1440),
            FieldSpec('seconds', '秒', numeric: true, required: false,
                maxLength: 2, minValue: 0, maxValue: 59, hint: '可留空，按 0 秒计算'),
          ],
          initial: {
            'minutes': originalLimitSeconds ~/ 60,
            'seconds': originalLimitSeconds % 60,
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
            final minutes = value['minutes'], seconds = value['seconds'] ?? 0;
            if (minutes is! int || minutes < 0 || minutes > 1440 ||
                seconds is! int || seconds < 0 || seconds > 59 ||
                minutes * 60 + seconds > 86400) {
              throw const ApiFailure(400, 'INVALID_QUOTA_DATE_DURATION');
            }
            return {'seconds': minutes * 60 + seconds};
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
    if (pending != null) return;
    await submitOriginal(recovering: false);
  }

  Future<void> recoverOriginal() async {
    if (pending == null) return;
    await submitOriginal(recovering: true);
  }

  Future<void> submitOriginal({required bool recovering}) async {
    if (!canAct || recoveryStopped || confirmingUnknownClose) return;
    if (recovering ? pending == null : pending != null) return;
    if ((pending == null && form.currentState?.validate() != true) ||
        calendar == null || subject == null) {
      return;
    }
    final data = pending ??
        Map<String, dynamic>.unmodifiable({
          'name': name.text.trim(),
          if (editing) 'state': state,
          if (!editing) ...{
            'subjectId': subject,
            'scope': application.isEmpty ? 'TOTAL' : 'APPLICATION',
            if (application.isNotEmpty) 'applicationId': application,
            'timeZone': calendar!['timeZone'],
            'effectiveFrom': effectiveDate,
          },
          'weeklyLimits': Map<String, int>.unmodifiable({
            for (final day in quotaWeek.keys)
              day: changedDays.contains(day)
                  ? int.parse(days[day]!.text) * 60
                  : preservedSeconds[day]!
          }),
          'dateOverrides': Map<String, int>.unmodifiable(overrides),
        });
    final operation = Object();
    saveOperation = operation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (recovering) {
        await owner.onRecoverUnknown(data);
      } else {
        await owner.onSubmit(data);
      }
      if (accepted && identical(saveOperation, operation)) {
        finish(allowCovered: true);
      }
    } catch (e) {
      if (accepted && identical(saveOperation, operation)) {
        if (privateFailure(e)) {
          invalidate();
          return;
        }
        setState(() {
          error = e;
          if (e is ApiFailure &&
              (e.status == 412 || isUnavailableOperationResult(e))) {
            recoveryFailure = e;
            pending = data;
          } else if (pending != null || e is! ApiFailure || e.status == 0 ||
              e.status == 408 || e.status >= 500 ||
              e.code == 'PENDING_OPERATION_UNCHANGED') {
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
    final confirmation = closeConfirmation;
    return PopScope(
      canPop: !busy && (pending == null || recoveryStopped),
      onPopInvoked: (didPop) {
        if (didPop) markClosed();
        if (!didPop && pending != null && !recoveryStopped && canAct) cancel();
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
                                                  helperText: !changedDays.contains(day.key) &&
                                                      preservedSeconds[day.key]! % 60 != 0
                                                      ? '当前额度 ${quotaDuration(preservedSeconds[day.key])}，不改此项会保留秒数'
                                                      : null),
                                              onChanged: (_) {
                                                if (!canEdit) return;
                                                setState(() => changedDays.add(day.key));
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
                                    : () => editOverride(),
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('添加日期'))
                          ]),
                          if (overrides.isEmpty)
                            const Text('暂无例外，所有日期按星期规则生成。',
                                style: TextStyle(color: muted)),
                          for (final date in (overrides.keys.toList()..sort()))
                            ListTile(
                                contentPadding: EdgeInsets.zero,
                                onTap: !canEdit ? null : () => editOverride(date),
                                title: Text(date),
                                subtitle: Text(quotaDuration(overrides[date])),
                                trailing: Wrap(children: [
                                  IconButton(
                                      key: Key('quota-plan-edit-override-$date'),
                                      tooltip: '编辑 $date 的例外',
                                      onPressed: !canEdit ? null : () => editOverride(date),
                                      icon: const Icon(Icons.edit_outlined, size: 18)),
                                  IconButton(
                                    tooltip: '删除 $date 的例外',
                                    onPressed: !canEdit
                                        ? null
                                        : () => removeOverride(date),
                                    icon: const Icon(Icons.close, size: 18)),
                                ])),
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
                          if (recoveryStopped) ...[
                            const SizedBox(height: 16),
                            const Notice('原提交已停止，输入以只读方式保留。请关闭后核对当前计划与版本；'
                                '结果到期或清除不代表保存没有发生。', warning: true),
                          ] else if (pending != null) ...[
                            const SizedBox(height: 16),
                            Notice(confirmingUnknownClose
                                ? '暂时关闭不会取消已经发出的保存。关闭后请先核对原工作空间的计划列表，避免重复创建或修改。'
                                : '上次提交结果尚未确认。输入已保留，请查询原保存结果。',
                                warning: true),
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
          if (confirmation != null) ...[
            TextButton(
                key: const Key('quota-plan-keep-unknown'),
                onPressed: canAct ? () => keepUnknown(confirmation) : null,
                child: const Text('继续核对')),
            FilledButton(
                key: const Key('quota-plan-confirm-close-unknown'),
                onPressed: canAct ? () => closeUnknown(confirmation) : null,
                child: const Text('确认关闭')),
          ] else ...[
            TextButton(
                key: pending != null && !recoveryStopped
                    ? const Key('quota-plan-close-unknown') : null,
                onPressed: canAct ? cancel : null,
                child: Text(recoveryStopped ? '关闭'
                    : pending != null ? '暂时关闭' : '取消')),
            FilledButton(
                key: pending != null && !recoveryStopped
                    ? const Key('quota-plan-query-original') : null,
                onPressed: !canAct || recoveryStopped || calendar == null
                    ? null : pending == null ? save : recoverOriginal,
                child: Text(busy
                    ? '保存中…'
                    : recoveryStopped
                        ? '已停止旧提交'
                        : pending != null
                            ? '查询原保存结果'
                            : '保存计划')),
          ],
        ],
      ));
  }
}
