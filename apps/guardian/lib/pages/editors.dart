import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/policy_domain_check.dart';
import '../core/policy_rule_directories.dart';
import '../core/rule_parameter_labels.dart';
import '../core/schedule_copy.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/dialog_access.dart';
import '../ui/editor_draft_text.dart';
import '../ui/owned_dialog_route.dart';
import 'device_subflow_scope.dart';
import 'schedule_exception_editor.dart';

const weekdays = [
  'MONDAY',
  'TUESDAY',
  'WEDNESDAY',
  'THURSDAY',
  'FRIDAY',
  'SATURDAY',
  'SUNDAY'
];
Map<String, String> options(Iterable<String> keys) =>
    {for (final k in keys) k: label(k)};
Map<String, String> entityOptions(List<Json> rows, String name) =>
    {for (final r in rows) r['id'] as String: r[name] as String};

bool _stopsEditorReplay(Object? failure) =>
    failure is ApiFailure &&
    (failure.status == 412 || isUnavailableOperationResult(failure));

Widget _stoppedDraftDialog(
        Object failure, String? draftText, VoidCallback? close,
        {Widget? review, String? checkNotice}) =>
    PopScope(
        canPop: false,
        onPopInvoked: (didPop) {
          if (!didPop) close?.call();
        },
        child: AlertDialog(
            scrollable: true,
            title: const Text('原提交需要重新核对'),
            content: SizedBox(
                width: 640,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FailureView(failure),
                      const SizedBox(height: 12),
                      const Text('旧请求已停止重试。以下保留的是本次输入，不代表已保存。'
                          '关闭后请核对最新记录，再重新打开编辑。'),
                      if (checkNotice != null) ...[
                        const SizedBox(height: 12),
                        Text(checkNotice),
                      ],
                      if (draftText != null)
                        ExpansionTile(
                            title: const Text('保留的草稿'),
                            subtitle: const Text('展开查看并选中复制'),
                            children: [
                              SelectableText(draftText),
                            ]),
                    ])),
            actions: [
              if (review != null) review,
              TextButton(
                  key: const Key('editor-close-stopped'),
                  onPressed: close,
                  child: const Text('关闭并刷新')),
            ]));

Future<bool> scheduleEditor(BuildContext context, Session session,
    {ScheduleCopy? copy,
    Listenable? accessChanges,
    bool Function()? hasAccess}) async {
  if (!session.authenticated) {
    throw const ApiFailure(401, 'UNAUTHENTICATED');
  }
  if (!session.canWrite || !session.canOpen('schedules')) {
    throw const ApiFailure(403, 'ACCESS_DENIED');
  }
  if (!context.mounted || session.tenant == null) return false;
  final root = session.root;
  final timeZone = session.tenant?['timeZone'] as String? ?? 'Asia/Shanghai';
  final access = DialogAccessBinding(context,
      accessChanges: accessChanges, hasAccess: hasAccess);
  var live = true;
  final scope = DeviceSubflowScope(session,
      permitted: () =>
          live &&
          access.permitted() &&
          context.mounted &&
          session.tenant != null &&
          session.root == root &&
          session.canWrite &&
          session.canOpen('schedules'));
  try {
    if (!scope.current) return false;
    final saved = await presentOwnedDialog<bool>(
        context,
        OwnedDialogRoute<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => ScheduleEditor(
                session: session,
                root: root,
                timeZone: timeZone,
                copy: copy,
                accessChanges: access.changes,
                operationScope: scope)));
    return saved == true && scope.current;
  } finally {
    live = false;
    scope.dispose();
    access.dispose();
  }
}

class ScheduleEditor extends StatefulWidget {
  final Session session;
  final String root;
  final String timeZone;
  final DeviceSubflowScope? operationScope;
  final ScheduleCopy? copy;
  final Listenable? accessChanges;
  const ScheduleEditor(
      {super.key,
      required this.session,
      required this.root,
      required this.timeZone,
      this.copy,
      this.accessChanges,
      this.operationScope});
  @override
  State<ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends State<ScheduleEditor> {
  final name = TextEditingController();
  late final zone = TextEditingController(text: widget.timeZone);
  final form = GlobalKey<FormState>();
  final days = <String>{...weekdays.take(5)};
  String start = '18:00', end = '20:00';
  List<Json> windows = [];
  List<Json> exceptions = [];
  Object? error;
  bool busy = false, resultUnknown = false, closing = false, exitOpen = false;
  bool revoked = false, reviewPriorSubmission = false, exceptionOpen = false;
  String? exceptionNotice;
  final exceptionLifetime = _EditorLifetime();
  Json? pendingBody, recoveryBody;
  ModalRoute<dynamic>? owner;
  OwnedDialogRoute<bool>? exitRoute;
  late final DeviceSubflowScope scope;
  late final bool ownsScope;
  late final Listenable? parentChanges;
  late final Api api;
  final key = requestId();

  bool get current =>
      mounted &&
      !closing &&
      !revoked &&
      scope.current &&
      owner?.isActive == true &&
      (owner is! OwnedDialogRoute<dynamic> ||
          (owner as OwnedDialogRoute<dynamic>).available);
  bool get interactive => current && owner?.isCurrent == true;
  bool get recoveryStopped => _stopsEditorReplay(error);
  bool get locked =>
      busy || resultUnknown || exitOpen || exceptionOpen || recoveryStopped;

  @override
  void initState() {
    super.initState();
    final copy = widget.copy;
    if (copy != null) {
      name.text = copy.suggestedName;
      zone.text = copy.timeZone;
      windows = copy.weekly.map((window) => Json.from(window)).toList();
      exceptions = copy.exceptions
          .map((exception) => {
                ...exception,
                'windows': (exception['windows'] as List)
                    .map((window) => Json.from(window as Json))
                    .toList(),
              })
          .toList();
    }
    ownsScope = widget.operationScope == null;
    scope = widget.operationScope ??
        DeviceSubflowScope(widget.session,
            permitted: () =>
                mounted &&
                !closing &&
                !revoked &&
                widget.session.tenant != null &&
                widget.session.root == widget.root &&
                widget.session.canWrite &&
                widget.session.canOpen('schedules'));
    // A covering dialog must not revoke an otherwise valid in-flight request.
    api = scope.api.scoped(() => current);
    scope.addListener(scopeChanged);
    parentChanges = widget.accessChanges;
    parentChanges?.addListener(scopeChanged);
    if (!scope.current) revoke();
  }

  void scopeChanged() {
    if (!scope.current) revoke();
  }

  @override
  void didUpdateWidget(covariant ScheduleEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session) ||
        oldWidget.root != widget.root ||
        !identical(oldWidget.copy, widget.copy) ||
        !identical(oldWidget.accessChanges, widget.accessChanges) ||
        !identical(oldWidget.operationScope, widget.operationScope)) {
      revoke();
    }
  }

  void revoke() {
    if (revoked || !mounted || closing) return;
    // Latch before any deferred rebuild: returning to the old scope cannot
    // revive captured callbacks or a request waiting for an authenticated client.
    revoked = true;
    exceptionLifetime.value = false;
    reviewPriorSubmission = busy || resultUnknown || pendingBody != null;
    pendingBody = null;
    recoveryBody = null;
    windows = [];
    exceptions = [];
    days.clear();
    error = null;
    exceptionNotice = null;
    exceptionOpen = false;
    busy = resultUnknown = false;

    void refresh() {
      if (!mounted || closing) return;
      name.clear();
      zone.clear();
      final confirmation = exitRoute;
      exitRoute = null;
      if (confirmation?.available == true) confirmation!.finish();
      setState(() => exitOpen = false);
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
    } else {
      refresh();
    }
  }

  bool privateFailure(Object failure) =>
      failure is ApiFailure &&
      (failure.code == 'WORKSPACE_CHANGED' ||
          failure.status == 403 ||
          (failure.status == 401 && failure.code != 'REAUTH_REQUIRED'));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ModalRoute.of(context);
    if (owner != null && !identical(owner, next)) closing = true;
    owner = next;
  }

  @override
  void dispose() {
    closing = true;
    exceptionLifetime.value = false;
    exceptionLifetime.dispose();
    scope.removeListener(scopeChanged);
    parentChanges?.removeListener(scopeChanged);
    if (ownsScope) scope.dispose();
    final confirmation = exitRoute;
    exitRoute = null;
    if (confirmation != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (confirmation.available) confirmation.finish();
      });
    }
    name.dispose();
    zone.dispose();
    super.dispose();
  }

  void closeOwnRoute({bool saved = false}) {
    if (!mounted || closing) return;
    final route = owner;
    final needsRefresh = saved || resultUnknown || recoveryStopped;
    if (route is OwnedDialogRoute<dynamic>) {
      if (!route.available) return;
      closing = true;
      route.finish(needsRefresh);
    } else if (route?.isCurrent == true) {
      closing = true;
      route!.navigator?.pop(needsRefresh);
    }
  }

  Future<void> requestClose() async {
    if (!interactive || busy || exitOpen || exceptionOpen) return;
    if (!resultUnknown) {
      closeOwnRoute();
      return;
    }
    setState(() => exitOpen = true);
    late final OwnedDialogRoute<bool> route;
    bool canRespond() =>
        current && !busy && resultUnknown && route.available && route.isCurrent;
    route = OwnedDialogRoute<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
                title: const Text('暂时关闭未确认的提交？'),
                content: const Text('服务器可能已保存此计划，关闭不会取消已提交的操作。'
                    '关闭后请先刷新时间计划列表核对结果，确认后再创建，避免重复提交。'
                    '继续留在这里可以按原内容重试。'),
                actions: [
                  TextButton(
                      key: const Key('schedule-editor-keep-unknown'),
                      onPressed: () {
                        if (canRespond()) route.finish(false);
                      },
                      child: const Text('继续核对')),
                  TextButton(
                      key: const Key('schedule-editor-confirm-close-unknown'),
                      onPressed: () {
                        if (canRespond()) route.finish(true);
                      },
                      child: const Text('暂时关闭')),
                ]));
    exitRoute = route;
    try {
      final confirmed = await presentOwnedDialog(context, route);
      if (confirmed == true && current && !busy && resultUnknown) {
        closeOwnRoute();
      }
    } finally {
      if (identical(exitRoute, route)) exitRoute = null;
      if (mounted && !closing) setState(() => exitOpen = false);
    }
  }

  Future<void> pickTime(bool first) async {
    if (!interactive || locked) return;
    final text = first ? start : end;
    final v = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(
            hour: int.parse(text.split(':')[0]),
            minute: int.parse(text.split(':')[1])),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
            child: child!));
    if (!interactive || locked || v == null) return;
    setState(() {
      final value =
          '${v.hour.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}';
      if (first) {
        start = value;
      } else {
        end = value;
      }
    });
  }

  Future<void> pickClosedDate() async {
    if (!interactive || locked) return;
    final now = DateTime.now();
    final d = await showDatePicker(
        context: context,
        firstDate: DateTime(1900),
        lastDate: DateTime(2200, 12, 31),
        initialDate: now);
    if (!interactive || locked || d == null) return;
    final date = d.toIso8601String().split('T')[0];
    if (exceptions.any((e) => e['date'] == date)) {
      setState(() => exceptionNotice = '该日期已有例外，可在下方调整。');
    } else if (exceptions.length >= 366) {
      setState(() => exceptionNotice = '日期例外最多 366 个，请先移除不需要的日期。');
    } else {
      setState(() {
        exceptionNotice = null;
        exceptions.add({'date': date, 'windows': <Json>[]});
      });
    }
  }

  Future<void> editException({Json? initial}) async {
    if (!interactive || locked) return;
    setState(() {
      exceptionOpen = true;
      exceptionNotice = null;
    });
    bool permitted() =>
        current &&
        exceptionLifetime.value &&
        !busy &&
        !resultUnknown &&
        !recoveryStopped;
    final changes = Listenable.merge([
      scope,
      exceptionLifetime,
      if (parentChanges != null) parentChanges!,
    ]);
    try {
      final date = initial == null
          ? await pickScheduleExceptionDate(context,
              accessChanges: changes, hasAccess: permitted)
          : DateTime.parse(initial['date'] as String);
      if (date == null || !mounted || !permitted() || !interactive) return;
      final day = date.toIso8601String().split('T')[0];
      final existing = exceptions.where((e) => e['date'] == day).firstOrNull;
      if (existing == null && exceptions.length >= 366) {
        setState(() => exceptionNotice = '日期例外最多 366 个，请先移除不需要的日期。');
        return;
      }
      final result = await editScheduleException(context,
          date: date,
          initial: existing,
          accessChanges: changes,
          hasAccess: permitted);
      if (result == null || !permitted() || result['date'] != day) return;
      setState(() {
        final index = exceptions.indexWhere((e) => e['date'] == day);
        if (index < 0) {
          exceptions.add(result);
        } else {
          exceptions[index] = result;
        }
        error = null;
        exceptionNotice = null;
      });
    } finally {
      if (mounted && !closing && !revoked) {
        setState(() => exceptionOpen = false);
      }
    }
  }

  void addWindow() {
    if (!interactive || locked) return;
    if (days.isEmpty || start == end) {
      setState(() => error = const ApiFailure(400, 'INVALID_TIME_WINDOW'));
      return;
    }
    setState(() {
      error = null;
      for (final day in days) {
        if (!windows.any(
            (w) => w['day'] == day && w['start'] == start && w['end'] == end)) {
          windows.add({'day': day, 'start': start, 'end': end});
        }
      }
    });
  }

  void removeWindow(Json window) {
    if (!interactive || locked) return;
    setState(() => windows.remove(window));
  }

  void removeException(Json exception) {
    if (!interactive || locked) return;
    setState(() {
      exceptions.remove(exception);
      exceptionNotice = null;
    });
  }

  Object? freeze(Object? value) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.unmodifiable(
          value.map((key, item) => MapEntry(key, freeze(item))));
    }
    if (value is List) return List<Object?>.unmodifiable(value.map(freeze));
    return value;
  }

  Future<void> save() async {
    if (!interactive || locked) return;
    if (form.currentState?.validate() != true) return;
    // Freeze every nested map/list before client acquisition or transport waits.
    pendingBody = freeze({
      'name': name.text.trim(),
      'definition': {
        'timeZone': zone.text.trim(),
        'weekly': windows,
        'exceptions': exceptions,
      }
    }) as Json;
    await submitOriginal();
  }

  Future<void> retryOriginal() async {
    if (!interactive ||
        busy ||
        exitOpen ||
        !resultUnknown ||
        pendingBody == null) {
      return;
    }
    await submitOriginal();
  }

  Future<void> submitOriginal() async {
    if (!current || busy || exitOpen || pendingBody == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await api.send('POST', '${widget.root}/schedules',
          key: key, body: pendingBody);
      if (!current) return;
      pendingBody = null;
      resultUnknown = false;
      closeOwnRoute(saved: true);
    } catch (failure) {
      if (!current) return;
      if (privateFailure(failure)) {
        revoke();
        return;
      }
      setState(() {
        error = failure;
        if (_stopsEditorReplay(failure)) {
          recoveryBody ??= pendingBody;
          pendingBody = null;
          resultUnknown = false;
        } else {
          resultUnknown = resultUnknown ||
              failure is! ApiFailure ||
              failure.status == 0 ||
              failure.status >= 500 ||
              failure.code == 'PENDING_OPERATION_UNCHANGED';
          if (!resultUnknown) pendingBody = null;
        }
      });
    } finally {
      if (mounted && !closing && !revoked) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (revoked || !scope.current) {
      return AlertDialog(
          scrollable: true,
          title: const Text('当前操作已失效'),
          content: SizedBox(
              width: 640,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('账户、工作空间或权限已变化，原计划内容已隐藏。'
                        '请关闭窗口，在当前工作空间重新打开。'),
                    if (reviewPriorSubmission) ...[
                      const SizedBox(height: 12),
                      const Text('如果先前的提交已经发出，仍需在有权限时核对原工作空间的计划列表。'
                          '关闭窗口不会取消已发出的请求。'),
                    ],
                  ])),
          actions: [
            TextButton(onPressed: closeOwnRoute, child: const Text('关闭'))
          ]);
    }
    if (recoveryStopped) {
      final draft = recoveryBody ?? pendingBody;
      return _stoppedDraftDialog(error!,
          draft == null ? null : scheduleDraftText(draft), closeOwnRoute);
    }
    return PopScope(
        canPop: !busy && !resultUnknown && !exitOpen && !exceptionOpen,
        onPopInvoked: (didPop) {
          if (!didPop && resultUnknown && !busy && !exitOpen) {
            unawaited(requestClose());
          }
        },
        child: AlertDialog(
            title: Text(widget.copy == null ? '创建时间计划' : '复制并调整时间计划'),
            content: SizedBox(
                width: 640,
                child: SingleChildScrollView(
                    child: Form(
                        key: form,
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (widget.copy != null) ...[
                                Text('复制自：${widget.copy!.name}',
                                    style: const TextStyle(color: muted)),
                                const SizedBox(height: 8),
                                const Notice('保存为新的时间计划，现有策略仍使用原计划。'
                                    '如需替换，请在策略草稿中明确选择新计划。'),
                                const SizedBox(height: 12),
                              ],
                              const Notice(
                                  '按当地时区设置允许使用的时段。结束时间早于开始时间表示跨午夜；日期例外会覆盖当天计划。'),
                              const SizedBox(height: 20),
                              TextFormField(
                                  controller: name,
                                  enabled: !locked,
                                  maxLength: 100,
                                  decoration: const InputDecoration(
                                      labelText: '计划名称',
                                      hintText: '例如：放学后的自由时间'),
                                  validator: (v) =>
                                      v == null || v.trim().isEmpty
                                          ? '请输入计划名称'
                                          : null),
                              const SizedBox(height: 12),
                              TextFormField(
                                  controller: zone,
                                  enabled: !locked,
                                  decoration:
                                      const InputDecoration(labelText: '时区'),
                                  validator: (v) =>
                                      v == null || v.trim().isEmpty
                                          ? '请输入时区'
                                          : null),
                              const SizedBox(height: 22),
                              const Text('每周时段',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w600)),
                              const SizedBox(height: 10),
                              if (windows.isEmpty)
                                const Notice('当前没有每周允许时段。日期例外仍按各自设置生效；'
                                    '没有允许例外的日期不可用。'),
                              Wrap(
                                  spacing: 6,
                                  children: weekdays
                                      .map((d) => FilterChip(
                                          label: Text(label(d)),
                                          selected: days.contains(d),
                                          onSelected: locked
                                              ? null
                                              : (v) {
                                                  if (!interactive || locked) {
                                                    return;
                                                  }
                                                  setState(() {
                                                    if (v) {
                                                      days.add(d);
                                                    } else {
                                                      days.remove(d);
                                                    }
                                                  });
                                                }))
                                      .toList()),
                              const SizedBox(height: 12),
                              Wrap(
                                  spacing: 12,
                                  runSpacing: 10,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    OutlinedButton.icon(
                                        onPressed: locked
                                            ? null
                                            : () => pickTime(true),
                                        icon: const Icon(Icons.schedule,
                                            size: 18),
                                        label: Text(start)),
                                    const Text('至'),
                                    OutlinedButton(
                                        onPressed: locked
                                            ? null
                                            : () => pickTime(false),
                                        child: Text(end)),
                                    TextButton.icon(
                                        onPressed: locked ? null : addWindow,
                                        icon: const Icon(Icons.add, size: 18),
                                        label: const Text('加入计划'))
                                  ]),
                              ...windows.asMap().entries.map((e) => ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                      '${label(e.value['day'])}  ${e.value['start']} – ${e.value['end']}'),
                                  trailing: IconButton(
                                      tooltip: '移除此时段',
                                      onPressed: locked
                                          ? null
                                          : () => removeWindow(e.value),
                                      icon:
                                          const Icon(Icons.close, size: 18)))),
                              const Divider(),
                              const SizedBox(height: 14),
                              const Text('日期例外',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w600)),
                              const SizedBox(height: 6),
                              const Text('特殊日期可全天关闭，或使用独立时段覆盖每周安排。',
                                  style: TextStyle(color: muted, fontSize: 12)),
                              Wrap(spacing: 8, children: [
                                TextButton.icon(
                                    onPressed: locked ? null : pickClosedDate,
                                    icon:
                                        const Icon(Icons.event_busy, size: 18),
                                    label: const Text('添加关闭日期')),
                                TextButton.icon(
                                    key: const Key(
                                        'schedule-add-custom-exception'),
                                    onPressed:
                                        locked ? null : () => editException(),
                                    icon: const Icon(
                                        Icons.edit_calendar_outlined,
                                        size: 18),
                                    label: const Text('设置特殊时段')),
                              ]),
                              if (exceptionNotice != null)
                                Notice(exceptionNotice!, warning: true),
                              ...exceptions.asMap().entries.map((e) => ListTile(
                                  key: Key(
                                      'schedule-exception-${e.value['date']}'),
                                  dense: true,
                                  onTap: locked
                                      ? null
                                      : () => editException(initial: e.value),
                                  title: Text('${e.value['date']} · '
                                      '${(e.value['windows'] as List).isEmpty ? '全天关闭' : (e.value['windows'] as List).map((window) => '${window['start']} – ${window['end']}').join('、')}'),
                                  trailing: Wrap(children: [
                                    IconButton(
                                        tooltip: '调整日期例外',
                                        onPressed: locked
                                            ? null
                                            : () =>
                                                editException(initial: e.value),
                                        icon: const Icon(Icons.edit_outlined,
                                            size: 18)),
                                    IconButton(
                                        tooltip: '移除例外',
                                        onPressed: locked
                                            ? null
                                            : () => removeException(e.value),
                                        icon:
                                            const Icon(Icons.close, size: 18)),
                                  ]))),
                              if (resultUnknown) ...[
                                const Notice(
                                    '尚不能确认保存结果，原内容已锁定。重试会使用同一次提交。'
                                    '暂时关闭后请先刷新时间计划列表核对结果，避免重复创建。',
                                    warning: true),
                                const SizedBox(height: 12),
                              ],
                              if (error != null)
                                FailureView(error!,
                                    reauth: resultUnknown || busy
                                        ? null
                                        : () {
                                            if (interactive && !locked) {
                                              widget.session
                                                  .login(stepUp: true);
                                            }
                                          })
                            ])))),
            actions: [
              TextButton(
                  key: resultUnknown
                      ? const Key('schedule-editor-close-unknown')
                      : null,
                  onPressed:
                      busy || exitOpen || exceptionOpen ? null : requestClose,
                  child: Text(resultUnknown ? '暂时关闭' : '取消')),
              if (resultUnknown)
                FilledButton(
                    key: const Key('schedule-editor-retry-original'),
                    onPressed: busy || exitOpen ? null : retryOriginal,
                    child: Text(busy ? '恢复中…' : '重试原提交'))
              else
                FilledButton(
                    onPressed: locked ? null : save,
                    child: Text(busy
                        ? '保存中…'
                        : widget.copy == null
                            ? '保存计划'
                            : '保存副本'))
            ]));
  }
}

const ruleEffects = {
  'APP_LAUNCH': ['ALLOW', 'DENY'],
  'APP_INSTALL': ['ALLOW', 'DENY'],
  'APP_UNINSTALL': ['ALLOW', 'PROTECT'],
  'RUNTIME_PERMISSION': ['DEFAULT', 'DENY'],
  'SPECIAL_ACCESS': ['DEFAULT', 'DENY', 'GRANT'],
  'DAILY_QUOTA': ['LIMIT'],
  'TIME_WINDOW': ['ALLOW'],
  'DOMAIN_ACCESS': ['ALLOW', 'DENY'],
  'USAGE_REMINDER': ['REMIND'],
};

/// True requests a fresh list after a saved or explicitly closed unknown write.
/// It never means that an unknown write has been confirmed successful.
Future<bool> policyEditor(BuildContext context, Session session,
    {Json? draft,
    Listenable? accessChanges,
    bool Function()? hasAccess}) async {
  if (!session.authenticated) {
    throw const ApiFailure(401, 'UNAUTHENTICATED');
  }
  if (!session.canWrite || !session.canOpen('policies')) {
    throw const ApiFailure(403, 'ACCESS_DENIED');
  }
  if (!context.mounted || session.tenant == null) return false;
  final root = session.root;
  final access = DialogAccessBinding(context,
      accessChanges: accessChanges, hasAccess: hasAccess);
  var live = true;
  final scope = DeviceSubflowScope(session,
      permitted: () =>
          live &&
          access.permitted() &&
          context.mounted &&
          session.tenant != null &&
          session.root == root &&
          session.canWrite &&
          session.canOpen('policies'));
  try {
    if (!scope.current) return false;
    final route = OwnedDialogRoute<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PolicyEditor(
            session: session,
            root: root,
            draft: draft,
            accessChanges: access.changes,
            operationScope: scope));
    final needsRefresh = await presentOwnedDialog(context, route);
    return needsRefresh == true && scope.current;
  } finally {
    live = false;
    scope.dispose();
    access.dispose();
  }
}

class RuntimePermissionCatalog {
  final Map<String, String> permissions;
  final List<String> editableEffects;
  const RuntimePermissionCatalog(this.permissions, this.editableEffects);
}

RuntimePermissionCatalog parseRuntimePermissionCatalog(dynamic raw) {
  final rows = raw is Json ? raw['permissions'] : null;
  final effects = raw is Json ? raw['editableEffects'] : null;
  if (raw is! Json ||
      raw.length != 3 ||
      raw['schemaVersion'] != 2 ||
      rows is! List ||
      rows.isEmpty ||
      rows.length > 100 ||
      effects is! List ||
      effects.length != 2 ||
      effects[0] != 'DEFAULT' ||
      effects[1] != 'DENY') {
    throw const ApiFailure(502, 'INVALID_PERMISSION_CATALOG_RESPONSE');
  }
  final result = <String, String>{};
  final pattern = RegExp(r'^android\.permission\.[A-Z][A-Z0-9_]{1,100}$');
  for (final value in rows) {
    if (value is! String ||
        !pattern.hasMatch(value) ||
        result.containsKey(value)) {
      throw const ApiFailure(502, 'INVALID_PERMISSION_CATALOG_RESPONSE');
    }
    final short = value.substring('android.permission.'.length);
    result[value] = runtimePermissionDisplayLabel(value) ?? short;
  }
  return RuntimePermissionCatalog(
      Map.unmodifiable(result), List.unmodifiable(effects.cast<String>()));
}

class PolicyEditor extends StatefulWidget {
  final Session session;
  final String root;

  /// Null loads on demand; an explicit list (including empty) is already read.
  final List<Json>? applications, schedules;
  final Json? draft;
  final DeviceSubflowScope? operationScope;
  final Listenable? accessChanges;
  const PolicyEditor(
      {super.key,
      required this.session,
      required this.root,
      this.applications,
      this.schedules,
      this.draft,
      this.accessChanges,
      this.operationScope});
  @override
  State<PolicyEditor> createState() => _PolicyEditorState();
}

class _PolicyEditorState extends State<PolicyEditor> {
  late final name = TextEditingController(text: widget.draft?['name'] ?? '');
  late String kind = widget.draft?['kind'] ?? 'POLICY';
  late List<Json> rules = (widget.draft?['rules'] as List? ?? [])
      .map((r) => Map<String, dynamic>.from(r))
      .toList();
  final form = GlobalKey<FormState>();
  bool busy = false;
  bool loadingRule = false;
  bool loadingNames = false;
  Object? directoryError;
  late final PolicyRuleDirectories directories;
  bool ruleOpen = false;
  bool resultUnknown = false,
      revoked = false,
      closing = false,
      disposed = false;
  bool saved = false, exitOpen = false;
  Object? error, recoveryFailure;
  String? checkNotice;
  Json? pendingBody, recoveryBody;
  late final DeviceSubflowScope scope;
  late final bool ownsScope;
  late final Listenable? parentChanges;
  ModalRoute<dynamic>? owner;
  late final Api api;
  final lifetime = _EditorLifetime();
  final ruleRoutes = <OwnedDialogRoute<dynamic>>{};
  final key = requestId();
  late final Object? policyId = widget.draft?['id'];
  late final Object? revision = widget.draft?['revision'];

  bool get current =>
      !disposed &&
      mounted &&
      !closing &&
      !revoked &&
      lifetime.value &&
      scope.current &&
      (owner == null ||
          (owner!.isActive &&
              (owner is! OwnedDialogRoute<dynamic> ||
                  (owner as OwnedDialogRoute<dynamic>).available)));
  bool get interactive => current && owner?.isCurrent == true;
  bool get recoveryStopped =>
      recoveryFailure != null || _stopsEditorReplay(error);
  bool get locked =>
      busy || loadingRule || ruleOpen || resultUnknown || recoveryStopped;

  @override
  void initState() {
    super.initState();
    ownsScope = widget.operationScope == null;
    scope = widget.operationScope ??
        DeviceSubflowScope(widget.session,
            permitted: () =>
                !disposed &&
                mounted &&
                !closing &&
                widget.session.root == widget.root &&
                widget.session.canWrite &&
                widget.session.canOpen('policies'));
    api = scope.api.scoped(() => current);
    directories = PolicyRuleDirectories(
        api: api,
        root: widget.root,
        current: () => current,
        applications: widget.applications,
        schedules: widget.schedules);
    scope.addListener(scopeChanged);
    parentChanges = widget.accessChanges;
    parentChanges?.addListener(scopeChanged);
    if (!scope.current) {
      revoked = true;
      name.clear();
      rules = [];
    }
    if (rules.any((rule) =>
        rule['applicationId'] != null || rule['scheduleId'] != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (current) {
          unawaited(readDirectories(() => directories.forReferences(rules),
              namesOnly: true));
        }
      });
    }
  }

  Future<bool> readDirectories(Future<void> Function() read,
      {bool namesOnly = false}) async {
    if (!current) return false;
    setState(() {
      directoryError = null;
      if (namesOnly) {
        loadingNames = true;
      } else {
        loadingRule = true;
      }
    });
    try {
      await read();
      return current;
    } catch (failure) {
      if (!current || privateFailure(failure)) {
        revoke();
      } else if (mounted) {
        setState(() => directoryError = failure);
      }
      return false;
    } finally {
      if (mounted && !disposed) {
        setState(() {
          if (namesOnly) {
            loadingNames = false;
          } else {
            loadingRule = false;
          }
        });
      }
    }
  }

  Future<void> reloadDirectories() async {
    if (!interactive || locked || loadingNames) return;
    await readDirectories(directories.reloadRequested, namesOnly: true);
  }

  void scopeChanged() {
    if (!current) revoke();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ModalRoute.of(context);
    if (owner != null && !identical(owner, next)) revoke();
    owner = next;
  }

  @override
  void didUpdateWidget(covariant PolicyEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session) ||
        oldWidget.root != widget.root ||
        oldWidget.operationScope != widget.operationScope ||
        !identical(oldWidget.accessChanges, widget.accessChanges) ||
        oldWidget.draft?['id'] != widget.draft?['id'] ||
        oldWidget.draft?['revision'] != widget.draft?['revision']) {
      revoke();
    }
  }

  void revoke() {
    if (disposed || revoked) return;
    revoked = true;
    lifetime.value = false;
    directories.revoke();
    name.clear();
    rules = [];
    pendingBody = null;
    recoveryBody = null;
    recoveryFailure = null;
    error = null;
    checkNotice = null;
    directoryError = null;
    loadingNames = false;
    resultUnknown = busy = loadingRule = ruleOpen = false;
    if (mounted) setState(() {});
  }

  bool privateFailure(Object failure) =>
      failure is ApiFailure &&
      (failure.code == 'WORKSPACE_CHANGED' ||
          failure.status == 403 ||
          (failure.status == 401 && failure.code != 'REAUTH_REQUIRED'));

  void finishOwnRoute() {
    if (!current) return;
    saved = true;
    closeOwnRoute();
  }

  void closeOwnRoute() {
    if (!mounted || disposed || closing) return;
    final route = owner;
    if (route is! OwnedDialogRoute<dynamic> || !route.available) return;
    final needsRefresh = saved || resultUnknown || recoveryStopped;
    closing = true;
    lifetime.value = false;
    route.finish(needsRefresh);
  }

  Future<void> requestClose() async {
    if (!mounted || disposed || closing || busy || exitOpen) return;
    if (!current) {
      closeOwnRoute();
      return;
    }
    if (!interactive) return;
    if (!resultUnknown) {
      closeOwnRoute();
      return;
    }
    setState(() => exitOpen = true);
    late final OwnedDialogRoute<bool> route;
    bool canRespond() =>
        current && !busy && resultUnknown && route.available && route.isCurrent;
    final changes = Listenable.merge([scope, lifetime]);
    route = OwnedDialogRoute<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AnimatedBuilder(
            animation: changes,
            builder: (_, __) => current
                ? AlertDialog(
                    title: const Text('暂时关闭未确认的提交？'),
                    content: const Text('服务器可能已保存本次内容。关闭后请先核对策略列表，'
                        '确认结果后再创建或修改，避免重复提交。继续留在这里可按原内容恢复或读取核对。'),
                    actions: [
                        TextButton(
                            key: const Key('policy-editor-keep-unknown'),
                            onPressed: () {
                              if (canRespond()) route.finish(false);
                            },
                            child: const Text('继续核对')),
                        TextButton(
                            key: const Key(
                                'policy-editor-confirm-close-unknown'),
                            onPressed: () {
                              if (canRespond()) route.finish(true);
                            },
                            child: const Text('暂时关闭')),
                      ])
                : AlertDialog(
                    title: const Text('工作空间或权限已变化'),
                    content: const Text('原提交内容已隐藏。请关闭后重新打开策略。'),
                    actions: [
                        TextButton(
                            onPressed: () {
                              if (route.available && route.isCurrent) {
                                route.finish();
                              }
                            },
                            child: const Text('关闭'))
                      ])));
    ruleRoutes.add(route);
    try {
      final confirmed = await presentOwnedDialog(context, route);
      if (confirmed == true && current && !busy && resultUnknown) {
        closeOwnRoute();
      }
    } finally {
      ruleRoutes.remove(route);
      if (disposed && ruleRoutes.isEmpty) lifetime.dispose();
      if (mounted && !disposed) setState(() => exitOpen = false);
    }
  }

  Future<T?> ruleDialog<T>(Widget Function(BuildContext) builder,
      {bool barrierDismissible = false}) async {
    if (!interactive || resultUnknown || busy) return null;
    final changes = Listenable.merge([scope, lifetime]);
    final route = OwnedDialogRoute<T>(
        context: context,
        barrierDismissible: barrierDismissible,
        builder: (inner) => AnimatedBuilder(
            animation: changes,
            builder: (_, __) => current
                ? builder(inner)
                : AlertDialog(
                    title: const Text('工作空间或权限已变化'),
                    content: const Text('原规则内容已隐藏。请关闭后重新打开策略。'),
                    actions: [
                        TextButton(
                            onPressed: () {
                              if (inner.mounted &&
                                  ModalRoute.of(inner)?.isCurrent == true) {
                                Navigator.of(inner).pop();
                              }
                            },
                            child: const Text('关闭'))
                      ])));
    ruleRoutes.add(route);
    try {
      return await presentOwnedDialog(context, route);
    } finally {
      ruleRoutes.remove(route);
      if (disposed && ruleRoutes.isEmpty) lifetime.dispose();
    }
  }

  @override
  void dispose() {
    disposed = true;
    directories.revoke();
    lifetime.value = false;
    scope.removeListener(scopeChanged);
    parentChanges?.removeListener(scopeChanged);
    if (ownsScope) scope.dispose();
    if (ruleRoutes.isEmpty) lifetime.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> editRule([int? index]) async {
    if (!interactive || locked) return;
    setState(() => ruleOpen = true);
    try {
      await editRuleContents(index);
    } finally {
      if (mounted && !disposed) setState(() => ruleOpen = false);
    }
  }

  Future<void> editRuleContents(int? index) async {
    String? type = index == null ? null : rules[index]['kind'];
    type ??= await ruleDialog<String>(
        (ctx) => SimpleDialog(
            title: const Text('选择规则类型'),
            children: ruleEffects.keys
                .map((t) => SimpleDialogOption(
                    onPressed: () {
                      if (current &&
                          ctx.mounted &&
                          ModalRoute.of(ctx)?.isCurrent == true) {
                        Navigator.pop(ctx, t);
                      }
                    },
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 14),
                    child: Text(label(t))))
                .toList()),
        barrierDismissible: true);
    if (!mounted) return;
    if (type == null || !interactive) return;
    final selectedType = type;
    final requiresApp = [
      'APP_LAUNCH',
      'APP_INSTALL',
      'APP_UNINSTALL',
      'RUNTIME_PERMISSION',
      'SPECIAL_ACCESS'
    ].contains(type);
    final hasApp = type != 'DOMAIN_ACCESS';
    if (hasApp &&
        !await readDirectories(() => directories.forRule(selectedType))) {
      return;
    }
    if (!mounted || !interactive) return;
    final apps = entityOptions(directories.applications, 'displayName');
    final plans = entityOptions(directories.schedules, 'name');
    final original = index == null ? null : rules[index];
    final oldApp = original?['applicationId'],
        oldPlan = original?['scheduleId'];
    final missingApp = oldApp is String && !apps.containsKey(oldApp);
    final missingPlan = oldPlan is String && !plans.containsKey(oldPlan);
    if (missingApp) {
      apps[oldApp] = '原应用（目录未找到） · ${shortId(oldApp)}';
    }
    if (missingPlan) {
      plans[oldPlan] = '原计划（目录未找到） · ${shortId(oldPlan)}';
    }
    if (requiresApp && apps.isEmpty) {
      toast(context, '请先在应用目录登记目标应用。');
      return;
    }
    if (type == 'TIME_WINDOW' && plans.isEmpty) {
      toast(context, '请先创建时间计划。');
      return;
    }
    Map<String, String> runtimePermissions = const {};
    List<String>? runtimeEffects;
    if (type == 'RUNTIME_PERMISSION') {
      setState(() => loadingRule = true);
      try {
        final raw = await api.send(
            'GET', '/policy-metadata/android-runtime-permissions');
        if (!current) return;
        final catalog = parseRuntimePermissionCatalog(raw);
        runtimePermissions = catalog.permissions;
        runtimeEffects = catalog.editableEffects;
      } catch (failure) {
        if (!current || privateFailure(failure)) {
          revoke();
        } else if (mounted) {
          toast(context,
              failure is ApiFailure ? failure.message : '无法加载权限目录，请稍后重试。');
        }
        return;
      } finally {
        if (mounted) setState(() => loadingRule = false);
      }
    }
    if (!mounted || !interactive) return;
    if (index != null &&
        type == 'RUNTIME_PERMISSION' &&
        !runtimePermissions.containsKey(rules[index]['permission'])) {
      toast(context, '原权限名称已不在当前目录中。请重新创建受支持的规则。');
      return;
    }
    if (index != null &&
        type == 'RUNTIME_PERMISSION' &&
        !runtimeEffects!.contains(rules[index]['effect'])) {
      toast(context, '原规则的自动授予动作目前不可编辑。请删除后选择系统默认或拒绝重新创建。');
      return;
    }
    final editableEffects = runtimeEffects ?? ruleEffects[type]!;
    final fields = [
      FieldSpec('effect', '规则行为', options: options(editableEffects)),
      if (hasApp)
        FieldSpec('applicationId', '目标应用',
            required: requiresApp,
            options: {if (!requiresApp) '': '所有适用应用', ...apps}),
      if (type == 'TIME_WINDOW')
        FieldSpec('scheduleId', '时间计划', options: plans),
      if (type == 'DAILY_QUOTA' || type == 'USAGE_REMINDER')
        const FieldSpec('seconds', '时长（秒，1–86400）',
            numeric: true, maxLength: 5),
      if (type == 'DOMAIN_ACCESS')
        const FieldSpec('domain', '域名',
            hint: 'example.com（不含协议或路径）', maxLength: 253),
      if (type == 'RUNTIME_PERMISSION')
        FieldSpec('permission', 'Android 运行时权限', options: runtimePermissions),
      if (type == 'SPECIAL_ACCESS')
        const FieldSpec('permission', '特殊访问权限', options: specialAccessNames),
      const FieldSpec('required', '执行要求',
          options: {'true': '必须支持', 'false': '可选执行'})
    ];
    final initial = index == null
        ? <String, dynamic>{'effect': editableEffects.first, 'required': 'true'}
        : {...rules[index], 'required': rules[index]['required'].toString()};
    final guidance = type == 'RUNTIME_PERMISSION'
        ? '可选择系统默认提示或拒绝。自动授予尚未开放；此处仅保存规则草稿，设备预览会说明支持情况，最终仍需提供方和设备回执。'
        : type == 'SPECIAL_ACCESS'
            ? '特殊访问通常需要设备本地用户或受管系统单独授权；保存规则不表示已经授予。'
            : type == 'DOMAIN_ACCESS'
                ? '支持中文和大小写域名。确认后会显示规范格式，保存草稿前可再次核对；只匹配这个域名，不包含子域。此步骤不保存或执行设备策略。'
                : null;
    final notices = [
      if (guidance != null) guidance,
      if (missingApp || missingPlan)
        '原应用或计划未在当前目录中找到，已保留原引用。请核对后选择可用项，不会自动替换成其他对象。'
    ];
    final result = await ruleDialog<Json>((ruleContext) => EditDialog(
        title: '${index == null ? '添加' : '编辑'}${label(type)}',
        fields: fields,
        description: notices.isEmpty ? null : notices.join('\n\n'),
        initial: initial,
        submit: type == 'DOMAIN_ACCESS'
            ? index == null
                ? '加入草稿'
                : '更新规则'
            : '保存',
        canCommit: false,
        onSubmit: (data) async {
          if (!current || resultUnknown) {
            throw const ApiFailure(409, 'WORKSPACE_CHANGED');
          }
          if (data['seconds'] != null &&
              (data['seconds'] < 1 || data['seconds'] > 86400)) {
            throw const ApiFailure(400, 'INVALID_DURATION');
          }
          final r = <String, dynamic>{
            'id': index == null
                ? 'rule_${requestId().substring(0, 12)}'
                : rules[index]['id'],
            'kind': selectedType,
            'effect': data['effect'],
            'required': data['required'] == 'true'
          };
          for (final field in [
            'applicationId',
            'scheduleId',
            'seconds',
            'permission',
            'domain'
          ]) {
            if (data[field] != null && data[field] != '') {
              r[field] = data[field];
            }
          }
          if (selectedType == 'DOMAIN_ACCESS') {
            final route = ModalRoute.of(ruleContext);
            bool childActive() =>
                ruleContext.mounted &&
                route?.isActive == true &&
                (route is! OwnedDialogRoute<dynamic> || route.available);
            bool ruleCurrent() => current && !resultUnknown && childActive();
            try {
              r['domain'] = await normalizePolicyDomain(api.scoped(ruleCurrent),
                  root: widget.root, domain: data['domain'] as String);
              if (!ruleCurrent()) {
                throw const ApiFailure(409, 'WORKSPACE_CHANGED');
              }
            } catch (failure) {
              if (privateFailure(failure) && childActive()) revoke();
              rethrow;
            }
          }
          return r;
        }));
    if (result != null && current) {
      setState(() {
        if (index == null) {
          rules.add(result);
        } else {
          rules[index] = result;
        }
      });
    }
  }

  Future<void> save() async {
    if (!interactive || locked) return;
    if (form.currentState?.validate() != true) return;
    // Copy nested rules before any asynchronous wait.
    // Every recovery uses this body, revision and request key unchanged.
    pendingBody = jsonDecode(jsonEncode({
      'name': name.text.trim(),
      if (widget.draft == null) 'kind': kind,
      'rules': rules,
    })) as Json;
    await submitOriginal();
  }

  Future<void> retryOriginal() async {
    if (!interactive || busy || !resultUnknown || pendingBody == null) return;
    await submitOriginal();
  }

  Future<void> submitOriginal() async {
    if (!current || busy || pendingBody == null) return;
    setState(() {
      busy = true;
      error = null;
      checkNotice = null;
    });
    try {
      final value = await api.send(policyId == null ? 'POST' : 'PUT',
          '${widget.root}/policies${policyId == null ? '' : '/$policyId'}',
          version: revision as int?, key: key, body: pendingBody);
      if (!current) return;
      if (!matchesPendingDraft(value)) {
        throw const ApiFailure(502, 'INVALID_POLICY_DRAFT_RESPONSE');
      }
      pendingBody = null;
      resultUnknown = false;
      finishOwnRoute();
    } catch (failure) {
      if (!current || privateFailure(failure)) {
        revoke();
        return;
      }
      setState(() {
        error = failure;
        if (_stopsEditorReplay(failure)) {
          recoveryBody ??= pendingBody;
          recoveryFailure = failure;
          pendingBody = null;
          resultUnknown = false;
        } else {
          resultUnknown = resultUnknown ||
              failure is! ApiFailure ||
              failure.status == 0 ||
              failure.status >= 500 ||
              failure.code == 'PENDING_OPERATION_UNCHANGED';
          if (!resultUnknown) pendingBody = null;
        }
      });
    } finally {
      if (mounted && !disposed) setState(() => busy = false);
    }
  }

  Future<void> checkResult() async {
    if (!interactive ||
        busy ||
        (!resultUnknown && !recoveryStopped) ||
        policyId == null ||
        (pendingBody == null && recoveryBody == null)) return;
    setState(() {
      busy = true;
      error = null;
      checkNotice = null;
    });
    try {
      final value = await api.send('GET', '${widget.root}/policies/$policyId');
      if (!current) return;
      if (matchesPendingDraft(value)) {
        pendingBody = null;
        recoveryBody = null;
        recoveryFailure = null;
        resultUnknown = false;
        finishOwnRoute();
      } else {
        setState(() => checkNotice = '读取到的草稿尚不能确认本次保存结果。请保留原内容恢复，或稍后再核对。');
      }
    } catch (failure) {
      if (!current || privateFailure(failure)) {
        revoke();
      } else {
        setState(() => error = failure);
      }
    } finally {
      if (mounted && !disposed) setState(() => busy = false);
    }
  }

  bool matchesPendingDraft(Object? value) {
    final body = pendingBody ?? recoveryBody;
    if (body == null ||
        value is! Json ||
        value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        value['revision'] is! int ||
        value['revision'] < 0 ||
        value['name'] != body['name'] ||
        value['kind'] != (policyId == null ? body['kind'] : kind) ||
        !_samePolicyRules(value['rules'], body['rules'])) return false;
    if (policyId == null) return value['revision'] == 0;
    return value['id'] == policyId &&
        revision is int &&
        (value['revision'] as int) > (revision as int);
  }

  void deleteRule(Object? id) {
    if (!interactive || locked || id is! String) return;
    final index = rules.indexWhere((rule) => rule['id'] == id);
    if (index >= 0) setState(() => rules.removeAt(index));
  }

  @override
  Widget build(BuildContext context) {
    if (!current) {
      return AlertDialog(
          title: Text(closing ? (saved ? '草稿已保存' : '正在返回原页面') : '工作空间或权限已变化'),
          content: Text(closing
              ? (saved ? '当前草稿已保存。' : '正在关闭当前编辑窗口。')
              : '原策略和规则内容已隐藏。请关闭窗口，在当前工作空间重新打开。'),
          actions: [
            TextButton(
                onPressed: closing ? null : closeOwnRoute,
                child: const Text('关闭'))
          ]);
    }
    if (recoveryStopped) {
      final draft = recoveryBody ?? pendingBody;
      return _stoppedDraftDialog(
          error ?? recoveryFailure!,
          draft == null
              ? null
              : policyDraftText(draft,
                  kind: kind,
                  applications: directories.applications,
                  schedules: directories.schedules),
          busy ? null : closeOwnRoute,
          checkNotice: checkNotice,
          review: policyId == null
              ? null
              : FilledButton(
                  key: const Key('policy-editor-check-result'),
                  onPressed: busy ? null : checkResult,
                  child: Text(busy ? '核对中…' : '读取并核对')));
    }
    return PopScope(
        canPop: !busy && !resultUnknown,
        onPopInvoked: (didPop) {
          if (!didPop && resultUnknown && !busy) unawaited(requestClose());
        },
        child: AlertDialog(
            title: Text(widget.draft == null ? '创建策略' : '编辑策略草稿'),
            content: SizedBox(
                width: 740,
                child: SingleChildScrollView(
                    child: Form(
                        key: form,
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Notice(
                                  '先保存草稿，再选择设备预览。配置保存与设备实际执行分别显示，发布前会检查设备能力。'),
                              const SizedBox(height: 20),
                              TextFormField(
                                  controller: name,
                                  enabled: !locked,
                                  maxLength: 100,
                                  decoration: const InputDecoration(
                                      labelText: '策略名称',
                                      hintText: '例如：学习日使用规则'),
                                  validator: (v) =>
                                      v == null || v.trim().isEmpty
                                          ? '请输入策略名称'
                                          : null),
                              if (widget.draft == null)
                                DropdownButtonFormField<String>(
                                    value: kind,
                                    decoration:
                                        const InputDecoration(labelText: '类型'),
                                    items: options(['POLICY', 'TEMPLATE'])
                                        .entries
                                        .map((e) => DropdownMenuItem(
                                            value: e.key, child: Text(e.value)))
                                        .toList(),
                                    onChanged: locked
                                        ? null
                                        : (v) {
                                            if (interactive &&
                                                !locked &&
                                                (v == 'POLICY' ||
                                                    v == 'TEMPLATE')) {
                                              setState(() => kind = v!);
                                            }
                                          }),
                              const SizedBox(height: 20),
                              Row(children: [
                                Text('规则 · ${rules.length}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                const Spacer(),
                                TextButton.icon(
                                    onPressed: locked || rules.length >= 100
                                        ? null
                                        : () => editRule(),
                                    icon: const Icon(Icons.add, size: 18),
                                    label: const Text('添加规则'))
                              ]),
                              if (loadingRule || loadingNames)
                                const LinearProgressIndicator(),
                              if (directoryError != null)
                                FailureView(directoryError!),
                              if (directories.hasRequested)
                                Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton.icon(
                                        onPressed: locked || loadingNames
                                            ? null
                                            : reloadDirectories,
                                        icon:
                                            const Icon(Icons.refresh, size: 18),
                                        label: const Text('重新加载选项'))),
                              if (rules.isEmpty)
                                const EmptyView('尚未添加规则', '可以先保存空草稿，稍后完善。'),
                              ...rules.asMap().entries.map((e) => Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  decoration: BoxDecoration(
                                      border: Border.all(color: line),
                                      borderRadius: BorderRadius.circular(8)),
                                  child: ListTile(
                                      leading:
                                          const Icon(Icons.rule, color: navy),
                                      title: Text(
                                          '${label(e.value['kind'])} · ${label(e.value['effect'])}'),
                                      subtitle: Text(ruleSummary(
                                          e.value,
                                          directories.applications,
                                          directories.schedules)),
                                      trailing: Wrap(children: [
                                        IconButton(
                                            tooltip: '编辑规则',
                                            onPressed: locked
                                                ? null
                                                : () => editRule(e.key),
                                            icon: const Icon(
                                                Icons.edit_outlined,
                                                size: 18)),
                                        IconButton(
                                            tooltip: '删除规则',
                                            onPressed: locked
                                                ? null
                                                : () =>
                                                    deleteRule(e.value['id']),
                                            icon: const Icon(Icons.close,
                                                size: 18))
                                      ])))),
                              if (resultUnknown) ...[
                                const Notice(
                                    '尚不能确认保存结果。已保留本次提交的原内容；'
                                    '请主动恢复原提交或读取核对，确认前暂不能编辑。',
                                    warning: true),
                                if (error != null) ...[
                                  const SizedBox(height: 8),
                                  const Notice('最近一次恢复或核对未完成。原提交仍保留，请稍后再试。',
                                      warning: true),
                                ],
                                if (checkNotice != null) ...[
                                  const SizedBox(height: 8),
                                  Notice(checkNotice!, warning: true),
                                ],
                              ],
                              if (error != null && !resultUnknown)
                                FailureView(error!, reauth: () {
                                  if (interactive && !locked) {
                                    widget.session.login(stepUp: true);
                                  }
                                })
                            ])))),
            actions: [
              TextButton(
                  key: resultUnknown
                      ? const Key('policy-editor-close-unknown')
                      : null,
                  onPressed: busy || exitOpen ? null : requestClose,
                  child: Text(resultUnknown ? '暂时关闭' : '取消')),
              if (resultUnknown) ...[
                if (error is ApiFailure &&
                    (error as ApiFailure).code == 'REAUTH_REQUIRED')
                  TextButton(
                      onPressed: busy
                          ? null
                          : () {
                              if (interactive && !busy) {
                                widget.session.login(stepUp: true);
                              }
                            },
                      child: const Text('重新安全验证')),
                if (policyId != null)
                  TextButton(
                      key: const Key('policy-editor-check-result'),
                      onPressed: busy ? null : checkResult,
                      child: const Text('读取核对')),
                OutlinedButton(
                    key: const Key('policy-editor-retry-original'),
                    onPressed: busy ? null : retryOriginal,
                    child: const Text('按原内容恢复')),
              ] else
                FilledButton(
                    onPressed: locked ? null : save,
                    child: Text(busy ? '保存中…' : '保存草稿'))
            ]));
  }
}

bool _samePolicyRules(Object? left, Object? right) {
  if (left is! List || right is! List || left.length != right.length) {
    return false;
  }
  const nullable = {
    'applicationId',
    'scheduleId',
    'seconds',
    'permission',
    'domain'
  };
  for (var index = 0; index < left.length; index++) {
    final actual = left[index];
    final expected = right[index];
    if (actual is! Map || expected is! Map) return false;
    Map<Object?, Object?> normalized(Map value) => {
          for (final entry in value.entries)
            if (!(nullable.contains(entry.key) && entry.value == null))
              entry.key: entry.value,
        };
    if (!_samePolicyValue(normalized(actual), normalized(expected))) {
      return false;
    }
  }
  return true;
}

bool _samePolicyValue(Object? left, Object? right) {
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every((key) =>
            right.containsKey(key) && _samePolicyValue(left[key], right[key]));
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_samePolicyValue(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}

class _EditorLifetime extends ValueNotifier<bool> {
  bool scheduled = false, disposed = false;
  _EditorLifetime() : super(true);

  @override
  void notifyListeners() {
    if (disposed) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (!scheduled) {
        scheduled = true;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          scheduled = false;
          if (!disposed) super.notifyListeners();
        });
      }
      return;
    }
    super.notifyListeners();
  }

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    super.dispose();
  }
}

String ruleSummary(Json rule, List<Json> apps, List<Json> schedules) {
  final parts = <String>[];
  if (rule['applicationId'] != null) {
    parts.add(apps
            .where((a) => a['id'] == rule['applicationId'])
            .firstOrNull?['displayName'] ??
        shortId(rule['applicationId']));
  }
  if (rule['scheduleId'] != null) {
    parts.add(schedules
            .where((a) => a['id'] == rule['scheduleId'])
            .firstOrNull?['name'] ??
        shortId(rule['scheduleId']));
  }
  if (rule['seconds'] != null) parts.add('${rule['seconds']} 秒');
  if (rule['domain'] != null) parts.add(rule['domain']);
  if (rule['permission'] != null) parts.add(rule['permission']);
  parts.add(rule['required'] == true ? '必须支持' : '可选');
  return parts.join(' · ');
}
