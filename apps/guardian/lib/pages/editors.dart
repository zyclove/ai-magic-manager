import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/rule_parameter_labels.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/owned_dialog_route.dart';
import 'device_subflow_scope.dart';

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

Future<void> scheduleEditor(BuildContext context, Session session) {
  final root = session.root;
  final timeZone = session.tenant?['timeZone'] as String? ?? 'Asia/Shanghai';
  return presentOwnedDialog<void>(context, OwnedDialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          ScheduleEditor(session: session, root: root, timeZone: timeZone)));
}

class ScheduleEditor extends StatefulWidget {
  final Session session;
  final String root;
  final String timeZone;
  const ScheduleEditor(
      {super.key,
      required this.session,
      required this.root,
      required this.timeZone});
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
  Json? pendingBody;
  ModalRoute<dynamic>? owner;
  OwnedDialogRoute<bool>? exitRoute;
  final key = requestId();

  bool get current => mounted && !closing && owner?.isActive == true &&
      (owner is! OwnedDialogRoute<void> ||
          (owner as OwnedDialogRoute<void>).available);
  bool get interactive => current && owner?.isCurrent == true;
  bool get locked => busy || resultUnknown || exitOpen;

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

  void closeOwnRoute() {
    if (!mounted || closing) return;
    final route = owner;
    if (route is OwnedDialogRoute<void>) {
      if (!route.available) return;
      closing = true;
      route.finish();
    } else if (route?.isCurrent == true) {
      closing = true;
      route!.navigator?.pop();
    }
  }

  Future<void> requestClose() async {
    if (!interactive || busy || exitOpen) return;
    if (!resultUnknown) {
      closeOwnRoute();
      return;
    }
    setState(() => exitOpen = true);
    late final OwnedDialogRoute<bool> route;
    bool canRespond() => current && !busy && resultUnknown &&
        route.available && route.isCurrent;
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
        firstDate: now.subtract(const Duration(days: 1)),
        lastDate: now.add(const Duration(days: 730)),
        initialDate: now);
    if (!interactive || locked || d == null) return;
    final date = d.toIso8601String().split('T')[0];
    if (!exceptions.any((e) => e['date'] == date)) {
      setState(() => exceptions.add({'date': date, 'windows': []}));
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
    setState(() => exceptions.remove(exception));
  }

  Object? freeze(Object? value) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.unmodifiable(value.map(
          (key, item) => MapEntry(key, freeze(item))));
    }
    if (value is List) return List<Object?>.unmodifiable(value.map(freeze));
    return value;
  }

  Future<void> save() async {
    if (!interactive || locked) return;
    if (form.currentState?.validate() != true) return;
    if (windows.isEmpty) {
      setState(() => error = const ApiFailure(400, 'ADD_TIME_WINDOW'));
      return;
    }
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
    if (!interactive || busy || exitOpen || !resultUnknown || pendingBody == null) {
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
      await widget.session.api.send('POST', '${widget.root}/schedules',
          key: key, body: pendingBody);
      if (!current) return;
      pendingBody = null;
      resultUnknown = false;
      closeOwnRoute();
    } catch (failure) {
      if (!current) return;
      setState(() {
        error = failure;
        resultUnknown = resultUnknown || failure is! ApiFailure ||
            failure.status == 0 || failure.status >= 500 ||
            failure.code == 'PENDING_OPERATION_UNCHANGED';
        if (!resultUnknown) pendingBody = null;
      });
    } finally {
      if (mounted && !closing) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy && !resultUnknown && !exitOpen,
      onPopInvoked: (didPop) {
        if (!didPop && resultUnknown && !busy && !exitOpen) {
          unawaited(requestClose());
        }
      },
      child: AlertDialog(
          title: const Text('创建时间计划'),
          content: SizedBox(
              width: 640,
              child: SingleChildScrollView(
                  child: Form(
                      key: form,
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Notice(
                                '按当地时区设置允许使用的时段。结束时间早于开始时间表示跨午夜；日期例外会覆盖当天计划。'),
                            const SizedBox(height: 20),
                            TextFormField(
                                controller: name,
                                enabled: !locked,
                                maxLength: 100,
                                decoration: const InputDecoration(
                                    labelText: '计划名称', hintText: '例如：放学后的自由时间'),
                                validator: (v) => v == null || v.trim().isEmpty
                                    ? '请输入计划名称'
                                    : null),
                            const SizedBox(height: 12),
                            TextFormField(
                                controller: zone,
                                enabled: !locked,
                                decoration:
                                    const InputDecoration(labelText: '时区'),
                                validator: (v) => v == null || v.trim().isEmpty
                                    ? '请输入时区'
                                    : null),
                            const SizedBox(height: 22),
                            const Text('每周时段',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 10),
                            Wrap(
                                spacing: 6,
                                children: weekdays
                                    .map((d) => FilterChip(
                                        label: Text(label(d)),
                                        selected: days.contains(d),
                                        onSelected: locked
                                            ? null
                                            : (v) {
                                                if (!interactive || locked) return;
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
                                      onPressed:
                                          locked ? null : () => pickTime(true),
                                      icon:
                                          const Icon(Icons.schedule, size: 18),
                                      label: Text(start)),
                                  const Text('至'),
                                  OutlinedButton(
                                      onPressed:
                                          locked ? null : () => pickTime(false),
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
                                    icon: const Icon(Icons.close, size: 18)))),
                            const Divider(),
                            const SizedBox(height: 14),
                            const Text('日期例外',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            const Text('假期或特殊日期可设置整天不可用。',
                                style: TextStyle(color: muted, fontSize: 12)),
                            TextButton.icon(
                                onPressed: locked ? null : pickClosedDate,
                                icon: const Icon(Icons.event_busy, size: 18),
                                label: const Text('添加关闭日期')),
                            ...exceptions.asMap().entries.map((e) => ListTile(
                                dense: true,
                                title: Text('${e.value['date']} · 全天关闭'),
                                trailing: IconButton(
                                    tooltip: '移除例外',
                                    onPressed: locked
                                        ? null
                                        : () => removeException(e.value),
                                    icon: const Icon(Icons.close, size: 18)))),
                            if (resultUnknown) ...[
                              const Notice(
                                  '尚不能确认保存结果，原内容已锁定。重试会使用同一次提交。'
                                  '暂时关闭后请先刷新时间计划列表核对结果，避免重复创建。',
                                  warning: true),
                              const SizedBox(height: 12),
                            ],
                            if (error != null)
                              FailureView(error!, reauth: resultUnknown || busy
                                  ? null
                                  : () {
                                      if (interactive && !locked) {
                                        widget.session.login(stepUp: true);
                                      }
                                    })
                          ])))),
          actions: [
            TextButton(
                key: resultUnknown
                    ? const Key('schedule-editor-close-unknown') : null,
                onPressed: busy || exitOpen ? null : requestClose,
                child: Text(resultUnknown ? '暂时关闭' : '取消')),
            if (resultUnknown)
              FilledButton(
                  key: const Key('schedule-editor-retry-original'),
                  onPressed: busy || exitOpen ? null : retryOriginal,
                  child: Text(busy ? '恢复中…' : '重试原提交'))
            else
              FilledButton(
                  onPressed: locked ? null : save,
                  child: Text(busy ? '保存中…' : '保存计划'))
          ]));
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
Future<void> policyEditor(BuildContext context, Session session,
    {Json? draft}) async {
  if (!session.authenticated) {
    throw const ApiFailure(401, 'UNAUTHENTICATED');
  }
  if (!session.canWrite || !session.canOpen('policies')) {
    throw const ApiFailure(403, 'ACCESS_DENIED');
  }
  if (!context.mounted || session.tenant == null) return;
  final root = session.root;
  var live = true;
  final scope = DeviceSubflowScope(session,
      permitted: () =>
          live &&
          context.mounted &&
          session.canWrite &&
          session.canOpen('policies'));
  Future<List<Json>> directory(String path) async {
    try {
      return await scope.api.all(path);
    } catch (failure) {
      if (failure is ApiFailure &&
          ((failure.status == 401 && failure.code != 'REAUTH_REQUIRED') ||
              failure.status == 403 ||
              failure.code == 'WORKSPACE_CHANGED')) {
        // Revoke both reads before the other directory can follow a cursor.
        live = false;
      }
      rethrow;
    }
  }

  try {
    late final List<List<Json>> data;
    try {
      data = await Future.wait<List<Json>>(
          [directory('$root/applications'), directory('$root/schedules')],
          eagerError: true);
    } catch (failure) {
      if (context.mounted && scope.current) {
        toast(context,
            failure is ApiFailure ? failure.message : '无法加载权限目录，请稍后重试。');
      }
      return;
    }
    if (!context.mounted || !scope.current) return;
    final route = OwnedDialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PolicyEditor(
            session: session,
            root: root,
            applications: data[0],
            schedules: data[1],
            draft: draft,
            operationScope: scope));
    await presentOwnedDialog(context, route);
  } finally {
    live = false;
    scope.dispose();
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
  final List<Json> applications, schedules;
  final Json? draft;
  final DeviceSubflowScope? operationScope;
  const PolicyEditor(
      {super.key,
      required this.session,
      required this.root,
      required this.applications,
      required this.schedules,
      this.draft,
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
  bool ruleOpen = false;
  bool resultUnknown = false,
      revoked = false,
      closing = false,
      disposed = false;
  bool saved = false, exitOpen = false;
  Object? error;
  String? checkNotice;
  Json? pendingBody;
  late final DeviceSubflowScope scope;
  late final bool ownsScope;
  late final Api api;
  final lifetime = _PolicyEditorLifetime();
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
      scope.current;
  bool get interactive => current && ModalRoute.of(context)?.isCurrent == true;
  bool get locked => busy || loadingRule || ruleOpen || resultUnknown;

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
    scope.addListener(scopeChanged);
    if (!scope.current) {
      revoked = true;
      name.clear();
      rules = [];
    }
  }

  void scopeChanged() {
    if (!current) revoke();
  }

  @override
  void didUpdateWidget(covariant PolicyEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session) ||
        oldWidget.root != widget.root ||
        oldWidget.operationScope != widget.operationScope ||
        oldWidget.draft?['id'] != widget.draft?['id'] ||
        oldWidget.draft?['revision'] != widget.draft?['revision']) {
      revoke();
    }
  }

  void revoke() {
    if (disposed || revoked) return;
    revoked = true;
    lifetime.value = false;
    name.clear();
    rules = [];
    pendingBody = null;
    error = null;
    checkNotice = null;
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
    final route = ModalRoute.of(context);
    if (route is! OwnedDialogRoute<void>) return;
    closing = true;
    lifetime.value = false;
    route.finish();
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
    if (!current || resultUnknown || busy) return null;
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
    lifetime.value = false;
    scope.removeListener(scopeChanged);
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
    if (type == null || !current) return;
    final selectedType = type;
    final requiresApp = [
      'APP_LAUNCH',
      'APP_INSTALL',
      'APP_UNINSTALL',
      'RUNTIME_PERMISSION',
      'SPECIAL_ACCESS'
    ].contains(type);
    final hasApp = type != 'DOMAIN_ACCESS';
    if (requiresApp && widget.applications.isEmpty) {
      toast(context, '请先在应用目录登记目标应用。');
      return;
    }
    if (type == 'TIME_WINDOW' && widget.schedules.isEmpty) {
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
    if (!mounted || !current) return;
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
        FieldSpec('applicationId', '目标应用', required: requiresApp, options: {
          if (!requiresApp) '': '所有适用应用',
          ...entityOptions(widget.applications, 'displayName')
        }),
      if (type == 'TIME_WINDOW')
        FieldSpec('scheduleId', '时间计划',
            options: entityOptions(widget.schedules, 'name')),
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
    final result = await ruleDialog<Json>((_) => EditDialog(
        title: '${index == null ? '添加' : '编辑'}${label(type)}',
        fields: fields,
        description: type == 'RUNTIME_PERMISSION'
            ? '可选择系统默认提示或拒绝。自动授予尚未开放；此处仅保存规则草稿，设备预览会说明支持情况，最终仍需提供方和设备回执。'
            : type == 'SPECIAL_ACCESS'
                ? '特殊访问通常需要设备本地用户或受管系统单独授权；保存规则不表示已经授予。'
                : null,
        initial: initial,
        submit: '保存',
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
        resultUnknown = resultUnknown ||
            failure is! ApiFailure ||
            failure.status == 0 ||
            failure.status >= 500 ||
            failure.code == 'PENDING_OPERATION_UNCHANGED';
        if (!resultUnknown) pendingBody = null;
      });
    } finally {
      if (mounted && !disposed) setState(() => busy = false);
    }
  }

  Future<void> checkResult() async {
    if (!interactive ||
        busy ||
        !resultUnknown ||
        policyId == null ||
        pendingBody == null) return;
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
    final body = pendingBody;
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
          title: Text(closing && saved ? '草稿已保存' : '工作空间或权限已变化'),
          content: Text(
              closing && saved ? '当前草稿已保存。' : '原策略和规则内容已隐藏。请关闭窗口，在当前工作空间重新打开。'),
          actions: [
            TextButton(
                onPressed: closing ? null : closeOwnRoute,
                child: const Text('关闭'))
          ]);
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
                              if (loadingRule) const LinearProgressIndicator(),
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
                                          widget.applications,
                                          widget.schedules)),
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

class _PolicyEditorLifetime extends ValueNotifier<bool> {
  bool scheduled = false, disposed = false;
  _PolicyEditorLifetime() : super(true);

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
