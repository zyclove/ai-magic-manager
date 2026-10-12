import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/session.dart';
import '../ui/design.dart';

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
  return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          ScheduleEditor(session: session, root: root, timeZone: timeZone));
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
  bool busy = false;
  final key = requestId();
  @override
  void dispose() {
    name.dispose();
    zone.dispose();
    super.dispose();
  }

  Future<void> pickTime(bool first) async {
    final text = first ? start : end;
    final v = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(
            hour: int.parse(text.split(':')[0]),
            minute: int.parse(text.split(':')[1])),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
            child: child!));
    if (v != null) {
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
  }

  void addWindow() {
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

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    if (windows.isEmpty) {
      setState(() => error = const ApiFailure(400, 'ADD_TIME_WINDOW'));
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.session.api
          .send('POST', '${widget.root}/schedules', key: key, body: {
        'name': name.text.trim(),
        'definition': {
          'timeZone': zone.text.trim(),
          'weekly': windows,
          'exceptions': exceptions
        }
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
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
                                maxLength: 100,
                                decoration: const InputDecoration(
                                    labelText: '计划名称', hintText: '例如：放学后的自由时间'),
                                validator: (v) => v == null || v.trim().isEmpty
                                    ? '请输入计划名称'
                                    : null),
                            const SizedBox(height: 12),
                            TextFormField(
                                controller: zone,
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
                                        onSelected: busy
                                            ? null
                                            : (v) => setState(() => v
                                                ? days.add(d)
                                                : days.remove(d))))
                                    .toList()),
                            const SizedBox(height: 12),
                            Wrap(
                                spacing: 12,
                                runSpacing: 10,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  OutlinedButton.icon(
                                      onPressed:
                                          busy ? null : () => pickTime(true),
                                      icon:
                                          const Icon(Icons.schedule, size: 18),
                                      label: Text(start)),
                                  const Text('至'),
                                  OutlinedButton(
                                      onPressed:
                                          busy ? null : () => pickTime(false),
                                      child: Text(end)),
                                  TextButton.icon(
                                      onPressed: busy ? null : addWindow,
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
                                    onPressed: busy
                                        ? null
                                        : () => setState(
                                            () => windows.removeAt(e.key)),
                                    icon: const Icon(Icons.close, size: 18)))),
                            const Divider(),
                            const SizedBox(height: 14),
                            const Text('日期例外',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            const Text('假期或特殊日期可设置整天不可用。',
                                style: TextStyle(color: muted, fontSize: 12)),
                            TextButton.icon(
                                onPressed: busy
                                    ? null
                                    : () async {
                                        final d = await showDatePicker(
                                            context: context,
                                            firstDate: DateTime.now().subtract(
                                                const Duration(days: 1)),
                                            lastDate: DateTime.now()
                                                .add(const Duration(days: 730)),
                                            initialDate: DateTime.now());
                                        if (d != null) {
                                          final date =
                                              d.toIso8601String().split('T')[0];
                                          if (!exceptions
                                              .any((e) => e['date'] == date)) {
                                            setState(() => exceptions.add(
                                                {'date': date, 'windows': []}));
                                          }
                                        }
                                      },
                                icon: const Icon(Icons.event_busy, size: 18),
                                label: const Text('添加关闭日期')),
                            ...exceptions.asMap().entries.map((e) => ListTile(
                                dense: true,
                                title: Text('${e.value['date']} · 全天关闭'),
                                trailing: IconButton(
                                    tooltip: '移除例外',
                                    onPressed: busy
                                        ? null
                                        : () => setState(
                                            () => exceptions.removeAt(e.key)),
                                    icon: const Icon(Icons.close, size: 18)))),
                            if (error != null)
                              FailureView(error!,
                                  reauth: () =>
                                      widget.session.login(stepUp: true))
                          ])))),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: busy ? null : save,
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
  final root = session.root;
  late final List<List<Json>> data;
  try {
    data = await Future.wait<List<Json>>([
      session.api.all('$root/applications'),
      session.api.all('$root/schedules')
    ]);
  } catch (failure) {
    if (context.mounted) {
      toast(context, failure is ApiFailure ? failure.message : '无法加载权限目录，请稍后重试。');
    }
    return;
  }
  if (!context.mounted || session.tenant?['id'] != root.substring(9)) return;
  await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PolicyEditor(
          session: session,
          root: root,
          applications: data[0],
          schedules: data[1],
          draft: draft));
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
  const common = {
    'CAMERA': '相机',
    'RECORD_AUDIO': '麦克风',
    'ACCESS_FINE_LOCATION': '精确位置',
    'ACCESS_COARSE_LOCATION': '大致位置',
    'ACCESS_BACKGROUND_LOCATION': '后台位置',
    'READ_CONTACTS': '读取联系人',
    'READ_CALENDAR': '读取日历',
    'POST_NOTIFICATIONS': '发送通知'
  };
  final result = <String, String>{};
  final pattern = RegExp(r'^android\.permission\.[A-Z][A-Z0-9_]{1,100}$');
  for (final value in rows) {
    if (value is! String || !pattern.hasMatch(value) || result.containsKey(value)) {
      throw const ApiFailure(502, 'INVALID_PERMISSION_CATALOG_RESPONSE');
    }
    final short = value.substring('android.permission.'.length);
    result[value] = common[short] == null ? short : '${common[short]} · $short';
  }
  return RuntimePermissionCatalog(
      Map.unmodifiable(result), List.unmodifiable(effects.cast<String>()));
}

class PolicyEditor extends StatefulWidget {
  final Session session;
  final String root;
  final List<Json> applications, schedules;
  final Json? draft;
  const PolicyEditor(
      {super.key,
      required this.session,
      required this.root,
      required this.applications,
      required this.schedules,
      this.draft});
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
  Object? error;
  final key = requestId();
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> editRule([int? index]) async {
    if (busy || loadingRule) return;
    String? type = index == null ? null : rules[index]['kind'];
    type ??= await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
            title: const Text('选择规则类型'),
            children: ruleEffects.keys
                .map((t) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, t),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 14),
                    child: Text(label(t))))
                .toList()));
    if (type == null || !mounted) return;
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
        final raw = await widget.session.api.send(
            'GET', '/policy-metadata/android-runtime-permissions');
        if (!mounted || widget.session.tenant?['id'] != widget.root.substring(9)) return;
        final catalog = parseRuntimePermissionCatalog(raw);
        runtimePermissions = catalog.permissions;
        runtimeEffects = catalog.editableEffects;
      } catch (failure) {
        if (mounted) {
          toast(context, failure is ApiFailure
              ? failure.message
              : '无法加载权限目录，请稍后重试。');
        }
        return;
      } finally {
        if (mounted) setState(() => loadingRule = false);
      }
    }
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
        FieldSpec('permission', 'Android 运行时权限',
            options: runtimePermissions),
      if (type == 'SPECIAL_ACCESS')
        const FieldSpec('permission', '特殊访问权限', options: {
          'USAGE_ACCESS': '使用情况访问',
          'OVERLAY': '悬浮窗',
          'NOTIFICATION_ACCESS': '通知读取',
          'ACCESSIBILITY': '无障碍服务',
          'VPN': 'VPN 连接'
        }),
      const FieldSpec('required', '执行要求',
          options: {'true': '必须支持', 'false': '可选执行'})
    ];
    final initial = index == null
        ? <String, dynamic>{
            'effect': editableEffects.first,
            'required': 'true'
          }
        : {...rules[index], 'required': rules[index]['required'].toString()};
    final result = await formDialog(context,
        title: '${index == null ? '添加' : '编辑'}${label(type)}',
        fields: fields,
        description: type == 'RUNTIME_PERMISSION'
            ? '可选择系统默认提示或拒绝。自动授予尚未开放；此处仅保存规则草稿，设备预览会说明支持情况，最终仍需提供方和设备回执。'
            : type == 'SPECIAL_ACCESS'
                ? '特殊访问通常需要设备本地用户或受管系统单独授权；保存规则不表示已经授予。'
                : null,
        initial: initial, onSubmit: (data) async {
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
        if (data[field] != null && data[field] != '') r[field] = data[field];
      }
      return r;
    });
    if (result != null && mounted) {
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
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.session.api.send(widget.draft == null ? 'POST' : 'PUT',
          '${widget.root}/policies${widget.draft == null ? '' : '/${widget.draft!['id']}'}',
          version: widget.draft?['revision'],
          key: key,
          body: {
            'name': name.text.trim(),
            if (widget.draft == null) 'kind': kind,
            'rules': rules
          });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
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
                                maxLength: 100,
                                decoration: const InputDecoration(
                                    labelText: '策略名称', hintText: '例如：学习日使用规则'),
                                validator: (v) => v == null || v.trim().isEmpty
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
                                  onChanged: busy
                                      ? null
                                      : (v) => setState(() => kind = v!)),
                            const SizedBox(height: 20),
                            Row(children: [
                              Text('规则 · ${rules.length}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              const Spacer(),
                              TextButton.icon(
                                  onPressed: busy || loadingRule || rules.length >= 100
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
                                    subtitle: Text(ruleSummary(e.value,
                                        widget.applications, widget.schedules)),
                                    trailing: Wrap(children: [
                                      IconButton(
                                          tooltip: '编辑规则',
                                          onPressed: busy || loadingRule
                                              ? null
                                              : () => editRule(e.key),
                                          icon: const Icon(Icons.edit_outlined,
                                              size: 18)),
                                      IconButton(
                                          tooltip: '删除规则',
                                          onPressed: busy || loadingRule
                                              ? null
                                              : () => setState(
                                                  () => rules.removeAt(e.key)),
                                          icon:
                                              const Icon(Icons.close, size: 18))
                                    ])))),
                            if (error != null)
                              FailureView(error!,
                                  reauth: () =>
                                      widget.session.login(stepUp: true))
                          ])))),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: busy || loadingRule ? null : save,
                child: Text(busy ? '保存中…' : '保存草稿'))
          ]));
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
