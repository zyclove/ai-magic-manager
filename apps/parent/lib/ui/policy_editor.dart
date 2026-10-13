import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/parent_api.dart';
import '../core/parent_session.dart';
import '../core/schedules.dart';
import 'schedule_center.dart';

const _kinds = <String, String>{
  'APP_LAUNCH': '应用启动',
  'APP_INSTALL': '应用安装',
  'APP_UNINSTALL': '应用卸载',
  'RUNTIME_PERMISSION': '系统运行时权限',
  'SPECIAL_ACCESS': '特殊访问',
  'DAILY_QUOTA': '每日额度',
  'TIME_WINDOW': '使用时段',
  'DOMAIN_ACCESS': '网站访问',
  'USAGE_REMINDER': '连续使用提醒',
};
const _effects = <String, List<String>>{
  'APP_LAUNCH': ['ALLOW', 'DENY'],
  'APP_INSTALL': ['ALLOW', 'DENY'],
  'APP_UNINSTALL': ['ALLOW', 'PROTECT'],
  'RUNTIME_PERMISSION': ['DEFAULT', 'DENY'],
  'SPECIAL_ACCESS': ['DEFAULT', 'DENY'],
  'DAILY_QUOTA': ['LIMIT'],
  'TIME_WINDOW': ['ALLOW'],
  'DOMAIN_ACCESS': ['ALLOW', 'DENY'],
  'USAGE_REMINDER': ['REMIND'],
};
const _labels = {
  'ALLOW': '允许',
  'DENY': '拒绝',
  'PROTECT': '禁止卸载',
  'DEFAULT': '遵循系统默认',
  'LIMIT': '限制时长',
  'REMIND': '提醒休息'
};
const _special = {
  'USAGE_ACCESS': '使用情况访问',
  'OVERLAY': '悬浮窗',
  'NOTIFICATION_ACCESS': '通知读取',
  'ACCESSIBILITY': '无障碍服务',
  'VPN': 'VPN 连接'
};

/// Edits a versioned draft only. Publishing remains a separate reviewed action.
/// Unknown rule fields survive untouched unless that rule is explicitly edited.
class PolicyDraftEditor extends StatefulWidget {
  final ParentSession session;
  final Json draft;
  const PolicyDraftEditor(
      {super.key, required this.session, required this.draft});
  @override
  State<PolicyDraftEditor> createState() => _PolicyDraftEditorState();
}

class _PolicyDraftEditorState extends State<PolicyDraftEditor> {
  late final tenant = widget.session.tenant!['id'];
  late final actor = widget.session.profile!['subject'];
  late final role = widget.session.role;
  late final name = TextEditingController(text: widget.draft['name']);
  late final rules = (widget.draft['rules'] as List)
      .map((r) => Map<String, dynamic>.from(r as Map))
      .toList();
  final form = GlobalKey<FormState>();
  bool dirty = false, busy = false, mustReload = false, allowExit = false;
  Object? error;

  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.tenant?['id'] == tenant &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role &&
      widget.session.canDecide;

  @override
  void initState() {
    super.initState();
    // Capture the scope before any asynchronous catalog request.
    tenant;
    actor;
    role;
    widget.session.addListener(_scopeChanged);
  }

  void _scopeChanged() {
    if (current || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (current || !mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    widget.session.removeListener(_scopeChanged);
    name.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    if (busy) return;
    if (dirty && !mustReload) {
      final discard = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                title: const Text('放弃尚未保存的修改？'),
                content: const Text('返回后，本次修改不会保留。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('继续编辑')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('放弃修改'))
                ],
              ));
      if (discard != true || !current) return;
    }
    if (!mounted) return;
    setState(() => allowExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _rule([int? index]) async {
    if (!current || busy || mustReload) return;
    final kind = index == null
        ? await showDialog<String>(
            context: context,
            builder: (ctx) => SimpleDialog(
                title: const Text('添加规则'),
                children: _kinds.entries
                    .map((entry) => SimpleDialogOption(
                        onPressed: () => Navigator.pop(ctx, entry.key),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 14),
                        child: Text(entry.value)))
                    .toList()))
        : rules[index]['kind'] as String?;
    if (!current || kind == null) return;
    if (!_effects.containsKey(kind) ||
        (index != null && !_effects[kind]!.contains(rules[index]['effect']))) {
      setState(() => error = '此规则暂不支持在手机端修改，可保留原规则或在完整管理台处理。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final needsApps = kind != 'DOMAIN_ACCESS';
      final apps = needsApps
          ? await widget.session.api.all('/tenants/$tenant/applications')
          : <Json>[];
      if (!current) return;
      final schedules = <Json>[];
      if (kind == 'TIME_WINDOW' &&
          index != null &&
          rules[index]['scheduleId'] is String) {
        final id = rules[index]['scheduleId'];
        final value = await widget.session.api
            .object('/tenants/$tenant/schedules/$id', isCurrent: () => current);
        if (value['id'] != id) {
          throw const ParentApiException(502, 'INVALID_RESPONSE');
        }
        schedules.add(value);
      }
      for (final schedule in schedules) {
        readSchedule(schedule);
      }
      if (!current) return;
      Map<String, String> permissions = _special;
      if (kind == 'RUNTIME_PERMISSION') {
        final catalog = await widget.session.api
            .object('/policy-metadata/android-runtime-permissions');
        final entries = catalog['permissions'];
        if (catalog['schemaVersion'] != 2 ||
            entries is! List ||
            entries.isEmpty ||
            entries.length > 100 ||
            catalog['editableEffects'] is! List ||
            (catalog['editableEffects'] as List).join(',') != 'DEFAULT,DENY' ||
            entries.any((e) =>
                e is! String ||
                !RegExp(r'^android\.permission\.[A-Z][A-Z0-9_]{1,100}$')
                    .hasMatch(e)) ||
            entries.toSet().length != entries.length) {
          throw const ParentApiException(502, 'INVALID_RESPONSE');
        }
        permissions = {
          for (final e in entries.cast<String>())
            e: e.replaceFirst('android.permission.', '')
        };
      }
      if (!mounted || !current) return;
      final result = await Navigator.of(context).push<Json>(MaterialPageRoute(
          builder: (_) => _RuleForm(
              kind: kind,
              initial: index == null ? null : rules[index],
              applications: apps,
              schedules: schedules,
              session: widget.session,
              permissions: permissions,
              isCurrent: () => current,
              scopeChanges: widget.session)));
      if (!current || result == null) return;
      setState(() {
        if (index == null) {
          rules.add(result);
        } else {
          rules[index] = result;
        }
        dirty = true;
      });
    } catch (failure) {
      if (current) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _remove(int index) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('移除此条草稿规则？'),
                content: const Text('仅修改当前草稿；已经保存的配置版本不会改变。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('移除'))
                ]));
    if (confirmed == true && current && !busy && !mustReload) {
      setState(() {
        rules.removeAt(index);
        dirty = true;
      });
    }
  }

  Future<void> _schedules() async {
    if (!current || busy || mustReload) return;
    setState(() => busy = true);
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ScheduleCenter(session: widget.session)));
    if (mounted) setState(() => busy = false);
  }

  Future<void> _save() async {
    if (!current || busy || mustReload || !form.currentState!.validate()) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final saved = await widget.session.api.send(
          'PUT', '/tenants/$tenant/policies/${widget.draft['id']}',
          version: widget.draft['revision'] as int,
          isCurrent: () => current && !widget.session.busy,
          body: {'name': name.text.trim(), 'rules': rules});
      if (!current) return;
      if (saved is! Json ||
          saved['id'] != widget.draft['id'] ||
          saved['revision'] != (widget.draft['revision'] as int) + 1 ||
          saved['rules'] is! List) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      setState(() {
        dirty = false;
        allowExit = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (current) Navigator.of(context).pop(saved);
      });
    } catch (failure) {
      if (!current) return;
      final uncertain = failure is! ParentApiException ||
          failure.status == 0 ||
          failure.status >= 500;
      setState(() {
        mustReload = uncertain || (!uncertain && failure.status == 412);
        error = uncertain ? '保存结果尚未确认。请返回查看最新草稿，核对后再编辑。系统不会自动重发。' : failure;
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: allowExit || (!dirty && !busy),
      onPopInvoked: (didPop) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
            title: const Text('编辑策略草稿'),
            leading: IconButton(
                onPressed: busy ? null : _leave,
                tooltip: '返回',
                icon: const Icon(Icons.arrow_back))),
        body: Form(
            key: form,
            child: ListView(padding: const EdgeInsets.all(20), children: [
              const Text('修改规则',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text('基于修订 ${widget.draft['revision']} · 保存后需重新预览并单独发布配置。'),
              const SizedBox(height: 20),
              TextFormField(
                  controller: name,
                  enabled: !busy && !mustReload,
                  maxLength: 100,
                  decoration: const InputDecoration(
                      labelText: '策略名称', border: OutlineInputBorder()),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? '请填写策略名称' : null,
                  onChanged: (_) => setState(() => dirty = true)),
              const SizedBox(height: 12),
              Text('规则 · ${rules.length}/100',
                  style: Theme.of(context).textTheme.titleLarge),
              OutlinedButton.icon(
                  onPressed: busy || mustReload ? null : _schedules,
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: const Text('查看或新建时间计划')),
              if (rules.isEmpty)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text('尚未添加规则。空草稿不会产生应用限制。')),
              for (int i = 0; i < rules.length; i++)
                Card(
                    child: ListTile(
                  title: Text(_kinds[rules[i]['kind']] ?? '暂不支持的规则'),
                  subtitle: Text(
                      '${_labels[rules[i]['effect']] ?? rules[i]['effect']} · ${rules[i]['required'] == true ? '必须支持' : '可选执行'}\n规则编号：${rules[i]['id']}'),
                  onTap: busy || mustReload ? null : () => _rule(i),
                  trailing: IconButton(
                      tooltip: '移除规则 ${i + 1}',
                      onPressed: busy || mustReload ? null : () => _remove(i),
                      icon: const Icon(Icons.delete_outline)),
                )),
              OutlinedButton.icon(
                  onPressed:
                      busy || mustReload || rules.length >= 100 ? null : _rule,
                  icon: const Icon(Icons.add),
                  label: const Text('添加规则')),
              if (busy) const LinearProgressIndicator(),
              if (error != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text('$error',
                        style: const TextStyle(color: Color(0xFF9A3931)))),
              if (mustReload)
                FilledButton(
                    onPressed: busy ? null : _leave,
                    child: const Text('返回核对最新草稿'))
              else
                FilledButton.icon(
                    onPressed: busy || !dirty ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存草稿')),
            ])),
      ));
}

class _RuleForm extends StatefulWidget {
  final ParentSession session;
  final String kind;
  final Json? initial;
  final List<Json> applications, schedules;
  final Map<String, String> permissions;
  final bool Function() isCurrent;
  final Listenable scopeChanges;
  const _RuleForm(
      {required this.session,
      required this.kind,
      required this.initial,
      required this.applications,
      required this.schedules,
      required this.permissions,
      required this.isCurrent,
      required this.scopeChanges});
  @override
  State<_RuleForm> createState() => _RuleFormState();
}

class _RuleFormState extends State<_RuleForm> {
  final form = GlobalKey<FormState>();
  late final schedules = List<Json>.from(widget.schedules);
  late String effect =
      widget.initial?['effect'] ?? _effects[widget.kind]!.first;
  late String app = widget.initial?['applicationId'] ?? '';
  late String schedule = widget.initial?['scheduleId'] ?? '';
  late String permission = widget.initial?['permission'] ?? '';
  late bool required = widget.initial?['required'] ?? true;
  late final seconds =
      TextEditingController(text: '${widget.initial?['seconds'] ?? 1800}');
  late final domain =
      TextEditingController(text: widget.initial?['domain'] ?? '');
  bool dirty = false, leaving = false;

  bool get requiresApp => const {
        'APP_LAUNCH',
        'APP_INSTALL',
        'APP_UNINSTALL',
        'RUNTIME_PERMISSION',
        'SPECIAL_ACCESS'
      }.contains(widget.kind);
  @override
  void initState() {
    super.initState();
    widget.scopeChanges.addListener(_scopeChanged);
  }

  void _scopeChanged() {
    if (!mounted || widget.isCurrent()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.isCurrent()) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    widget.scopeChanges.removeListener(_scopeChanged);
    seconds.dispose();
    domain.dispose();
    super.dispose();
  }

  Future<void> _back() async {
    if (leaving) return;
    if (dirty) {
      final discard = await showDialog<bool>(
          context: context,
          builder: (ctx) =>
              AlertDialog(title: const Text('放弃这条规则的修改？'), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('继续编辑')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('放弃修改'))
              ]));
      if (discard != true || !mounted) return;
    }
    setState(() => leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Widget select(String label, String value, Map<String, String> options,
          ValueChanged<String> change) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: DropdownButtonFormField<String>(
              isExpanded: true,
              value: options.containsKey(value) ? value : null,
              decoration: InputDecoration(
                  labelText: label, border: const OutlineInputBorder()),
              items: options.entries
                  .map((e) => DropdownMenuItem(
                      value: e.key,
                      child: Text(e.value, overflow: TextOverflow.ellipsis)))
                  .toList(),
              validator: (v) =>
                  v == null || !options.containsKey(v) ? '请选择当前目录中的有效选项' : null,
              onChanged: (v) {
                if (v != null) {
                  setState(() {
                    dirty = true;
                    change(v);
                  });
                }
              }));

  Future<void> _selectSchedule() async {
    if (!widget.isCurrent()) return;
    final plan = await Navigator.of(context).push<Json>(MaterialPageRoute(
      builder: (_) => ScheduleCenter(session: widget.session, choosing: true),
    ));
    if (!mounted || !widget.isCurrent() || plan == null) return;
    final selected = readSchedule(plan);
    setState(() {
      schedules.removeWhere((s) => s['id'] == selected['id']);
      schedules.add(selected);
      schedule = selected['id'];
      dirty = true;
    });
  }

  void _done() {
    if (!widget.isCurrent() || !form.currentState!.validate()) return;
    final result = <String, dynamic>{
      'id':
          widget.initial?['id'] ?? 'r_${const Uuid().v4().replaceAll('-', '')}',
      'kind': widget.kind,
      'effect': effect,
      'required': required,
      if (widget.kind != 'DOMAIN_ACCESS' && app.isNotEmpty)
        'applicationId': app,
      if (widget.kind == 'TIME_WINDOW') 'scheduleId': schedule,
      if (const {'DAILY_QUOTA', 'USAGE_REMINDER'}.contains(widget.kind))
        'seconds': int.parse(seconds.text),
      if (const {'RUNTIME_PERMISSION', 'SPECIAL_ACCESS'}.contains(widget.kind))
        'permission': permission,
      if (widget.kind == 'DOMAIN_ACCESS')
        'domain': domain.text.trim().toLowerCase(),
    };
    setState(() => leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isCurrent()) Navigator.pop(context, result);
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: leaving || !dirty,
      onPopInvoked: (didPop) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
            title: Text(_kinds[widget.kind]!),
            leading: IconButton(
                tooltip: '返回',
                onPressed: _back,
                icon: const Icon(Icons.arrow_back))),
        body: Form(
            key: form,
            child: ListView(padding: const EdgeInsets.all(20), children: [
              select(
                  '规则行为',
                  effect,
                  {for (final e in _effects[widget.kind]!) e: _labels[e]!},
                  (v) => effect = v),
              if (widget.kind != 'DOMAIN_ACCESS')
                select(
                    '目标应用',
                    app,
                    {
                      if (!requiresApp) '': '所有适用应用',
                      for (final a in widget.applications)
                        a['id'] as String:
                            '${a['displayName']} · ${a['packageName']} · ${a['platform']}',
                    },
                    (v) => app = v),
              if (requiresApp && widget.applications.isEmpty)
                const Text('请先在完整管理台登记应用，然后返回重新添加。'),
              if (widget.kind == 'TIME_WINDOW') ...[
                select(
                    '时间计划',
                    schedule,
                    {
                      for (final s in schedules)
                        s['id'] as String: s['name'] as String
                    },
                    (v) => schedule = v),
                OutlinedButton.icon(
                    onPressed: _selectSchedule,
                    icon: const Icon(Icons.calendar_month_outlined),
                    label: const Text('选择或新建时间计划')),
                for (final plan in schedules.where((p) => p['id'] == schedule))
                  ScheduleDefinitionView(definition: plan['definition']),
              ],
              if (const {'DAILY_QUOTA', 'USAGE_REMINDER'}.contains(widget.kind))
                TextFormField(
                    controller: seconds,
                    keyboardType: TextInputType.number,
                    maxLength: 5,
                    decoration: const InputDecoration(
                        labelText: '时长（秒）',
                        helperText: '1–86400 秒；1800 秒 = 30 分钟',
                        border: OutlineInputBorder()),
                    onChanged: (_) => setState(() => dirty = true),
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null || n < 1 || n > 86400
                          ? '请输入 1–86400 的整数'
                          : null;
                    }),
              if (const {'RUNTIME_PERMISSION', 'SPECIAL_ACCESS'}
                  .contains(widget.kind)) ...[
                select('权限项目', permission, widget.permissions,
                    (v) => permission = v),
                const Text('配置不等于系统授权。实际可执行范围会在设备预览中说明。'),
              ],
              if (widget.kind == 'DOMAIN_ACCESS')
                TextFormField(
                    controller: domain,
                    maxLength: 253,
                    decoration: const InputDecoration(
                        labelText: '域名',
                        hintText: 'example.com',
                        helperText: '不含协议、路径或通配符；国际域名请填写 Punycode',
                        border: OutlineInputBorder()),
                    onChanged: (_) => setState(() => dirty = true),
                    validator: (v) {
                      final d = (v ?? '').trim().toLowerCase();
                      return d.length > 253 ||
                              !d.contains('.') ||
                              RegExp(r'^[0-9.]+$').hasMatch(d) ||
                              d.split('.').any((p) =>
                                  p.isEmpty ||
                                  p.length > 63 ||
                                  !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$')
                                      .hasMatch(p))
                          ? '请输入完整有效域名，如 example.com'
                          : null;
                    }),
              const SizedBox(height: 18),
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('必须支持'),
                  subtitle: const Text('设备不支持时，阻止强制发布；关闭则允许报告为可选规则。'),
                  value: required,
                  onChanged: (v) => setState(() {
                        required = v;
                        dirty = true;
                      })),
              const SizedBox(height: 20),
              FilledButton(onPressed: _done, child: const Text('完成规则编辑')),
              const SizedBox(height: 8),
              const Text('返回草稿后仍需点击“保存草稿”。'),
            ])),
      ));
}
