import 'package:flutter/material.dart';

import '../core/paged_collection.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';

const _ink = Color(0xFF17324B);
const _muted = Color(0xFF315E86);

/// Mobile policy reader and explicit device preview. Publication is a separate
/// workflow: a preview never changes an Android setting or grants enforcement.
Future<void> showPolicyCenter(BuildContext context, ParentSession session) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => PolicyCenter(session: session),
  ));
}

class PolicyCenter extends StatefulWidget {
  final ParentSession session;
  const PolicyCenter({super.key, required this.session});

  @override
  State<PolicyCenter> createState() => _PolicyCenterState();
}

class _PolicyCenterState extends State<PolicyCenter> {
  late final String tenantId;
  late final String actor;
  late final String role;
  late final PagedCollection policies;

  @override
  void initState() {
    super.initState();
    tenantId = widget.session.tenant!['id'] as String;
    actor = widget.session.profile!['subject'] as String;
    role = widget.session.role;
    policies =
        PagedCollection(widget.session.api, '/tenants/$tenantId/policies');
    widget.session.addListener(_closeIfScopeChanged);
  }

  bool get _current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.tenant?['id'] == tenantId &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;

  void _closeIfScopeChanged() {
    if (mounted && !_current) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    widget.session.removeListener(_closeIfScopeChanged);
    policies.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('策略中心')),
        body: AnimatedBuilder(
          animation: policies,
          builder: (context, _) {
            if (!policies.loaded && policies.error != null) {
              return _error(policies.error!, policies.reload);
            }
            if (!policies.loaded) {
              return const Center(child: CircularProgressIndicator());
            }
            return RefreshIndicator(
              onRefresh: policies.reload,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text('策略草稿与模板',
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                color: _ink,
                                fontWeight: FontWeight.w700,
                              )),
                  const SizedBox(height: 7),
                  const Text('先选择草稿，再核对目标设备和逐项规则。预览不会改变设备设置。',
                      style: TextStyle(color: _muted)),
                  const SizedBox(height: 18),
                  if (policies.items.isEmpty)
                    const Card(
                        child: Padding(
                            padding: EdgeInsets.all(20),
                            child: Text('还没有策略。请先在完整管理台创建草稿或模板。'))),
                  for (final row in policies.items)
                    Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 9),
                        leading:
                            const Icon(Icons.shield_outlined, color: _muted),
                        title: Text(_name(row['name'], '未命名策略')),
                        subtitle: Text(
                            '${row['kind'] == 'TEMPLATE' ? '模板 · 需先复制' : '策略草稿'} · ${(row['rules'] as List?)?.length ?? 0} 条规则 · 修订 ${row['revision'] ?? '—'}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: row['id'] is String && _current
                            ? () => Navigator.of(context)
                                    .push(MaterialPageRoute<void>(
                                  builder: (_) => _PolicyDetail(
                                      session: widget.session,
                                      policyId: row['id'] as String),
                                ))
                            : null,
                      ),
                    ),
                  if (policies.error != null)
                    Text('${policies.error}',
                        style: const TextStyle(color: Color(0xFF9A3931))),
                  if (policies.loadingMore) const LinearProgressIndicator(),
                  if (policies.hasMore)
                    TextButton.icon(
                      onPressed:
                          policies.loadingMore ? null : policies.loadMore,
                      icon: const Icon(Icons.expand_more),
                      label: const Text('加载更多策略'),
                    ),
                ],
              ),
            );
          },
        ),
      );
}

class _PolicyDetail extends StatefulWidget {
  final ParentSession session;
  final String policyId;
  const _PolicyDetail({required this.session, required this.policyId});

  @override
  State<_PolicyDetail> createState() => _PolicyDetailState();
}

class _PolicyDetailState extends State<_PolicyDetail> {
  late final String tenantId;
  late final String actor;
  late final String role;
  PagedCollection? devices;
  late Future<Json> draft;
  final selected = <String, String>{};
  final selectedNames = <String, String>{};
  Json? preview;
  bool busy = false;
  Object? actionError;

  @override
  void initState() {
    super.initState();
    tenantId = widget.session.tenant!['id'] as String;
    actor = widget.session.profile!['subject'] as String;
    role = widget.session.role;
    if (widget.session.canDecide) {
      devices =
          PagedCollection(widget.session.api, '/tenants/$tenantId/devices');
    }
    widget.session.addListener(_closeIfScopeChanged);
    draft = _readDraft();
  }

  bool get _current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.tenant?['id'] == tenantId &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;

  void _closeIfScopeChanged() {
    if (mounted && !_current) Navigator.of(context).pop();
  }

  Future<Json> _readDraft() async {
    final result = await widget.session.api
        .object('/tenants/$tenantId/policies/${widget.policyId}');
    if (result['id'] != widget.policyId ||
        result['name'] is! String ||
        result['revision'] is! int ||
        result['rules'] is! List ||
        !const {'POLICY', 'TEMPLATE'}.contains(result['kind'])) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return result;
  }

  void _reload() {
    setState(() {
      preview = null;
      actionError = null;
      selected.clear();
      selectedNames.clear();
      draft = _readDraft();
    });
    devices?.reload();
  }

  void _toggleDevice(Json row) {
    final id = row['id'];
    final registration = row['registrationId'];
    if (busy || id is! String) return;
    setState(() {
      preview = null;
      actionError = null;
      if (selected.containsKey(id)) {
        selected.remove(id);
        selectedNames.remove(id);
      } else if (registration is String &&
          row['state'] == 'ACTIVE' &&
          selected.length < 50) {
        selected[id] = registration;
        selectedNames[id] = _name(row['displayName'], '未命名设备');
      }
    });
  }

  Future<void> _preview(Json policy) async {
    if (!_current ||
        busy ||
        !widget.session.canDecide ||
        policy['kind'] != 'POLICY' ||
        selected.isEmpty ||
        selected.length > 50) return;
    final revision = policy['revision'];
    if (revision is! int) return;
    final expected = Map<String, String>.from(selected);
    setState(() {
      busy = true;
      actionError = null;
      preview = null;
    });
    try {
      final raw = await widget.session.api.send(
          'POST', '/tenants/$tenantId/policies/${widget.policyId}/previews',
          version: revision,
          body: {'deviceIds': expected.keys.toList()},
          maxResponseBytes: 4 * 1024 * 1024);
      if (!_current) return;
      if (raw is! Json ||
          raw['id'] is! String ||
          raw['policyId'] != widget.policyId ||
          raw['draftRevision'] != revision ||
          raw['phase'] != 'PREVIEW' ||
          raw['hash'] is! String ||
          raw['enforceable'] is! bool ||
          raw['targets'] is! List ||
          raw['expiresAt'] is! int ||
          (raw['expiresAt'] as int) <= DateTime.now().millisecondsSinceEpoch ||
          raw['snapshot'] is! Json ||
          (raw['snapshot'] as Json)['groupSelection'] != null) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      final returned = <String, String>{};
      for (final target in raw['targets'] as List) {
        if (target is! Json ||
            target['deviceId'] is! String ||
            target['registrationId'] is! String ||
            target['rules'] is! List ||
            (target['rules'] as List).any((rule) =>
                rule is! Json ||
                rule['kind'] is! String ||
                rule['status'] is! String ||
                (rule['reasonCode'] != null && rule['reasonCode'] is! String) ||
                rule['warnings'] is! List) ||
            returned.containsKey(target['deviceId'])) {
          throw const ParentApiException(502, 'INVALID_RESPONSE');
        }
        returned[target['deviceId'] as String] =
            target['registrationId'] as String;
      }
      if (returned.length != expected.length ||
          expected.entries.any((entry) => returned[entry.key] != entry.value) ||
          selected.length != expected.length ||
          expected.entries.any((entry) => selected[entry.key] != entry.value)) {
        throw const ParentApiException(409, 'RESOURCE_VERSION_CONFLICT');
      }
      setState(() => preview = raw);
    } catch (failure) {
      if (_current) setState(() => actionError = failure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_closeIfScopeChanged);
    devices?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('策略详情与预览')),
        body: FutureBuilder<Json>(
          future: draft,
          builder: (context, snapshot) {
            if (snapshot.hasError) return _error(snapshot.error!, _reload);
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final policy = snapshot.data!;
            return RefreshIndicator(
              onRefresh: () async {
                _reload();
                try {
                  await draft;
                } catch (_) {
                  // The FutureBuilder displays the scoped read failure.
                }
              },
              child: ListView(padding: const EdgeInsets.all(20), children: [
                Text(_name(policy['name'], '未命名策略'),
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(color: _ink, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(
                    '${policy['kind'] == 'TEMPLATE' ? '模板' : '策略草稿'} · 修订 ${policy['revision']} · ${(policy['rules'] as List).length} 条规则',
                    style: const TextStyle(color: _muted)),
                const SizedBox(height: 16),
                for (final raw in policy['rules'] as List)
                  if (raw is Json)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.rule_outlined),
                        title: Text(
                            '${_rule(raw['kind'])} · ${_effect(raw['effect'])}'),
                        subtitle: Text(_ruleDetail(raw)),
                      ),
                    ),
                if (policy['kind'] == 'TEMPLATE')
                  const Card(
                      child: Padding(
                          padding: EdgeInsets.all(18),
                          child: Text('模板不能直接预览或发布。请先在完整管理台复制为策略草稿。')))
                else if (!widget.session.canDecide)
                  const Card(
                      child: Padding(
                          padding: EdgeInsets.all(18),
                          child: Text('当前角色可查看策略，不能预览或发布。')))
                else ...[
                  const SizedBox(height: 18),
                  Text('选择目标设备 · ${selected.length}/50',
                      style: Theme.of(context).textTheme.titleLarge),
                  const Text('本次为明确设备快照。设备组成员后续变化不会自动更新此策略。',
                      style: TextStyle(color: _muted)),
                  const SizedBox(height: 10),
                  _devicePicker(),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: busy || selected.isEmpty
                        ? null
                        : () => _preview(policy),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: Text(busy ? '正在检查设备…' : '预览所选设备'),
                  ),
                ],
                if (actionError != null) ...[
                  const SizedBox(height: 12),
                  Text('$actionError',
                      style: const TextStyle(color: Color(0xFF9A3931))),
                ],
                if (preview != null) ...[
                  const SizedBox(height: 18),
                  _previewContent(preview!),
                ],
              ]),
            );
          },
        ),
      );

  Widget _devicePicker() => AnimatedBuilder(
        animation: devices!,
        builder: (context, _) {
          final devices = this.devices!;
          if (!devices.loaded && devices.error != null) {
            return _error(devices.error!, devices.reload);
          }
          if (!devices.loaded) return const LinearProgressIndicator();
          return Column(children: [
            if (devices.items.isEmpty) const Text('当前没有可选择的设备，请先完成设备注册。'),
            for (final row in devices.items)
              Card(
                child: CheckboxListTile(
                  value: selected.containsKey(row['id']),
                  onChanged: !busy &&
                          row['id'] is String &&
                          (selected.containsKey(row['id']) ||
                              (row['state'] == 'ACTIVE' &&
                                  row['registrationId'] is String &&
                                  selected.length < 50))
                      ? (_) => _toggleDevice(row)
                      : null,
                  title: Text(_name(row['displayName'], '未命名设备')),
                  subtitle: Text(
                      '${row['platform'] == 'ANDROID_TV' ? 'Android TV' : 'Android'} · ${row['state'] == 'ACTIVE' ? '已注册' : '不可选择'}'),
                ),
              ),
            if (devices.error != null)
              Text('${devices.error}',
                  style: const TextStyle(color: Color(0xFF9A3931))),
            if (devices.loadingMore) const LinearProgressIndicator(),
            if (devices.hasMore)
              TextButton.icon(
                onPressed: devices.loadingMore ? null : devices.loadMore,
                icon: const Icon(Icons.expand_more),
                label: const Text('加载更多设备'),
              ),
          ]);
        },
      );

  Widget _previewContent(Json result) {
    final targets = result['targets'] as List;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('设备检查结果', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 7),
      Text('预览有效期：${_time(result['expiresAt'])} · ${targets.length} 台设备',
          style: const TextStyle(color: _muted)),
      const SizedBox(height: 9),
      const Card(
          child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                  '这是配置预览，不会更改设备设置。服务端当前尚未开放系统强制执行；“支持”只表示预览检查通过，不代表规则已经生效。'))),
      for (final raw in targets)
        if (raw is Json)
          Card(
            margin: const EdgeInsets.only(top: 10),
            child: ExpansionTile(
              title: Text(selectedNames[raw['deviceId']] ?? '未命名设备'),
              subtitle: Text(
                  '设备观察：${_observation(raw['observationStatus'])} · ${(raw['rules'] as List).length} 项规则'),
              children: [
                for (final rule in raw['rules'] as List)
                  if (rule is Json)
                    ListTile(
                      title: Text(
                          '${_rule(rule['kind'])} · ${_status(rule['status'])}'),
                      subtitle: Text(_evaluationDetail(rule)),
                    ),
              ],
            ),
          ),
    ]);
  }
}

Widget _error(Object error, VoidCallback retry) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('$error', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: retry,
            icon: const Icon(Icons.refresh),
            label: const Text('重新加载'),
          ),
        ]),
      ),
    );

String _name(Object? value, String fallback) =>
    value is String && value.trim().isNotEmpty ? value : fallback;

String _time(Object? millis) {
  if (millis is! int || millis <= 0) return '暂无记录';
  final value = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
}

String _rule(Object? kind) => switch (kind) {
      'APP_LAUNCH' => '应用启动',
      'APP_INSTALL' => '应用安装',
      'APP_UNINSTALL' => '应用卸载保护',
      'RUNTIME_PERMISSION' => '系统运行时权限',
      'SPECIAL_ACCESS' => '特殊访问权限',
      'DAILY_QUOTA' => '每日额度',
      'TIME_WINDOW' => '可用时段',
      'DOMAIN_ACCESS' => '网站访问',
      'USAGE_REMINDER' => '使用提醒',
      _ => '其他规则',
    };

String _effect(Object? effect) => switch (effect) {
      'ALLOW' => '允许',
      'DENY' => '拒绝',
      'DEFAULT' => '系统默认',
      'GRANT' => '授予',
      'PROTECT' => '保护',
      'LIMIT' => '限制',
      'REMIND' => '提醒',
      _ => '待核对',
    };

String _ruleDetail(Json rule) {
  final parts = <String>[
    rule['required'] == true ? '必须支持' : '可选执行',
    if (rule['applicationId'] is String) '应用 ${rule['applicationId']}',
    if (rule['scheduleId'] is String) '时段 ${rule['scheduleId']}',
    if (rule['seconds'] is int) '${rule['seconds']} 秒',
    if (rule['domain'] is String) '${rule['domain']}',
    if (rule['permission'] is String) '${rule['permission']}',
  ];
  return parts.join(' · ');
}

String _status(Object? value) => switch (value) {
      'SUPPORTED_PENDING' => '能力支持 · 等待执行',
      'UNSUPPORTED' => '预览不支持',
      'UNVERIFIED' => '应用身份未核验',
      'UNAVAILABLE' => '设备当前不可用',
      'STALE' => '能力报告已过期',
      'UNKNOWN' => '能力尚未核验',
      _ => '状态待核对',
    };

String _reason(Object? value) => switch (value) {
      'AWAITING_EXECUTION' => '仅预览支持，仍待设备实际执行',
      'CAPABILITY_NOT_VERIFIED' => '尚无可验证的设备能力证据',
      'AUTO_GRANT_NOT_AVAILABLE' => '不能自动授予该系统权限',
      'SYSTEM_USER_ACTION_REQUIRED' => '需设备用户在系统设置中操作',
      'APPLICATION_IDENTITY_NOT_VERIFIED' => '应用签名或安装身份尚未核验',
      'DEVICE_NOT_ACTIVE' => '设备未处于有效注册状态',
      'APPLICATION_PLATFORM_MISMATCH' => '应用与设备平台不匹配',
      'APPLICATION_PROFILE_NOT_VERIFIED' => '应用安装位置尚未核验',
      _ => value is String && value.isNotEmpty ? value : '无额外说明',
    };

String _evaluationDetail(Json rule) {
  final warnings = rule['warnings'];
  final notes = warnings is List
      ? warnings.map(_warning).where((value) => value.isNotEmpty).toList()
      : <String>[];
  return '原因：${_reason(rule['reasonCode'])}${notes.isEmpty ? '' : '\n提示：${notes.join('、')}'}';
}

String _warning(Object? value) => switch (value) {
      'SAME_LAYER_CONFLICT_RESTRICTIVE_WINS' => '同层冲突取更严格结果',
      'SMALLER_QUOTA_WINS' => '额度取更短时长',
      'INSTALL_DENY_MAY_REMOVE_EXISTING_APP' => '拒绝安装可能影响现有应用',
      'SYSTEM_USER_ACTION_REQUIRED' => '仍需设备用户操作',
      _ => value is String ? value : '',
    };

String _observation(Object? value) => switch (value) {
      'RECENT' => '近期有设备报告',
      'STALE' => '设备报告已过期',
      _ => '尚无有效设备报告',
    };
