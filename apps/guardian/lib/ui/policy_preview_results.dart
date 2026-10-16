import 'dart:async';
import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/labels.dart';
import 'design.dart';

/// A read-only view of one immutable preview. It grants no execution or refresh
/// authority; the existing guarded dialog owns every publication action.
class PolicyPreviewResults extends StatefulWidget {
  final Json preview;
  final Map<String, String> names;
  final String? selectionSummary;
  const PolicyPreviewResults(
      {super.key,
      required this.preview,
      required this.names,
      this.selectionSummary});

  @override
  State<PolicyPreviewResults> createState() => _PolicyPreviewResultsState();
}

class _PolicyPreviewResultsState extends State<PolicyPreviewResults> {
  Timer? expiryTimer;
  @override
  void initState() {
    super.initState();
    scheduleExpiry();
  }

  @override
  void didUpdateWidget(PolicyPreviewResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    scheduleExpiry();
  }

  void scheduleExpiry() {
    expiryTimer?.cancel();
    final now = DateTime.now().millisecondsSinceEpoch;
    final deadlines = <int>[
      if (_timestamp(widget.preview['expiresAt']) case final int expires)
        expires,
      for (final target in _objects(widget.preview['targets']))
        for (final evidence in _objects(target['applicationEvidence']))
          if (_timestamp(evidence['expiresAt']) case final int expires) expires,
    ].where((value) => value > now).toList()
      ..sort();
    if (deadlines.isEmpty) return;
    final wait = (deadlines.first - now + 1).clamp(1, 86400000).toInt();
    expiryTimer = Timer(Duration(milliseconds: wait), () {
      if (!mounted) return;
      setState(() {});
      scheduleExpiry();
    });
  }

  @override
  void dispose() {
    expiryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.preview;
    final targets = _objects(p['targets']);
    final rules = targets.expand((target) => _objects(target['rules']));
    var supported = 0, limited = 0, unknown = 0;
    for (final rule in rules) {
      switch (_bucket(rule['status'])) {
        case 0:
          supported++;
        case 1:
          limited++;
        default:
          unknown++;
      }
    }
    final snapshot =
        p['snapshot'] is Json ? p['snapshot'] as Json : <String, dynamic>{};
    final applications = <String, String>{
      for (final app in _objects(snapshot['applications']))
        if (app['id'] is String && app['displayName'] is String)
          app['id'] as String: app['displayName'] as String,
    };
    final expires = _timestamp(p['expiresAt']);
    final expired =
        expires == null || expires <= DateTime.now().millisecondsSinceEpoch;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Notice('这是发布前检查，尚未执行设备系统管控。'),
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _Pill('${targets.length} 台设备', navy),
        _Pill('${supported + limited + unknown} 项检查', navy),
        _Pill('受限 $limited 项', const Color(0xFF8A4C13)),
        _Pill('待核验 $unknown 项', muted),
        _Pill('支持条件满足 $supported 项', navy),
      ]),
      const SizedBox(height: 12),
      if (widget.selectionSummary != null) Text(widget.selectionSummary!),
      const SizedBox(height: 4),
      Text(expired ? '预览已过期，请关闭后重新预览。' : '预览有效至 ${_date(expires)}',
          style: TextStyle(color: expired ? const Color(0xFFA7473C) : muted)),
      const SizedBox(height: 20),
      const Text('逐设备检查',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      const Text('展开设备查看规则限制和应用核验，检查数量按设备计算。', style: TextStyle(color: muted)),
      const SizedBox(height: 12),
      for (final target in targets)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _DeviceChecks(
            key: ValueKey(
                '${p['id']}/${target['deviceId']}/${target['registrationId']}'),
            target: target,
            name: widget.names[target['deviceId']] ?? '未命名设备',
            applications: applications,
          ),
        ),
      const SizedBox(height: 4),
      const ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.only(bottom: 12),
          title: Text('保存配置与快照说明', style: TextStyle(fontSize: 14)),
          children: [
            Text(
                '本次保存只记录当前设备快照。设备组成员日后变化不会自动影响此版本。保存配置需要近期多因素认证，保存前会再次核对权限、组版本及核验记录。',
                style: TextStyle(color: muted)),
          ]),
    ]);
  }
}

class _DeviceChecks extends StatefulWidget {
  final Json target;
  final String name;
  final Map<String, String> applications;
  const _DeviceChecks(
      {super.key,
      required this.target,
      required this.name,
      required this.applications});
  @override
  State<_DeviceChecks> createState() => _DeviceChecksState();
}

class _DeviceChecksState extends State<_DeviceChecks> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) {
    final target = widget.target;
    final rules = _objects(target['rules']);
    final apps =
        rules.map((rule) => rule['applicationId']).whereType<String>().toSet();
    final limited = rules.where((rule) => _bucket(rule['status']) == 1).length;
    final unknown = rules.where((rule) => _bucket(rule['status']) == 2).length;
    return ExpansionTile(
      onExpansionChanged: (value) => setState(() => expanded = value),
      tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: line)),
      collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: line)),
      title: Text(widget.name,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('${rules.length} 项检查 · 受限 $limited 项 · 待核验 $unknown 项',
              style: const TextStyle(fontSize: 12, color: muted))),
      children: !expanded
          ? const []
          : [
              Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            '设备上报：${_observation(target['observationStatus'])}',
                            style: const TextStyle(color: muted, fontSize: 12)),
                        const SizedBox(height: 12),
                        if (rules.isEmpty) const Text('此设备没有检查项'),
                        for (final rule in rules)
                          _RuleCheck(
                              rule: rule, applications: widget.applications),
                        if (apps.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          const Text('此设备的应用核验',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          for (final app in apps)
                            _ApplicationEvidence(
                                target: target,
                                applicationId: app,
                                name: widget.applications[app] ?? '应用名称未提供'),
                        ],
                      ])),
            ],
    );
  }
}

class _RuleCheck extends StatelessWidget {
  final Json rule;
  final Map<String, String> applications;
  const _RuleCheck({required this.rule, required this.applications});
  @override
  Widget build(BuildContext context) {
    final sourceIds = rule['sourceRuleIds'];
    final count =
        sourceIds is List ? sourceIds.whereType<String>().toSet().length : 0;
    final warnings = rule['warnings'] is List
        ? (rule['warnings'] as List).whereType<String>()
        : const <String>[];
    final appId = rule['applicationId'];
    final subject = appId is String
        ? applications[appId] ?? '应用名称未提供'
        : rule['domain'] is String
            ? rule['domain'] as String
            : null;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration:
          BoxDecoration(color: canvas, borderRadius: BorderRadius.circular(6)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_kind(rule['kind']),
            style: const TextStyle(fontWeight: FontWeight.w600)),
        if (subject != null)
          Text(subject, style: const TextStyle(color: muted)),
        const SizedBox(height: 6),
        Text('拟配置：${_effect(rule['predictedEffect'])}',
            style: const TextStyle(color: muted)),
        if (rule['seconds'] is int && (rule['seconds'] as int) > 0)
          Text('时长：${rule['seconds']} 秒', style: const TextStyle(color: muted)),
        Text(_ruleStatus(rule['status']),
            style: TextStyle(
                color: _bucket(rule['status']) == 1
                    ? const Color(0xFF8A4C13)
                    : navy)),
        const SizedBox(height: 4),
        Text(_reason(rule['reasonCode'])),
        if (rule['required'] == true)
          const Text('此项为必需条件', style: TextStyle(fontSize: 12, color: muted)),
        if (count > 1)
          Text('合并自 $count 条规则',
              style: const TextStyle(fontSize: 12, color: muted)),
        for (final warning in warnings)
          Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('提示：${_reason(warning)}',
                  style: const TextStyle(fontSize: 12, color: muted))),
      ]),
    );
  }
}

class _ApplicationEvidence extends StatelessWidget {
  final Json target;
  final String applicationId, name;
  const _ApplicationEvidence(
      {required this.target, required this.applicationId, required this.name});
  @override
  Widget build(BuildContext context) {
    final records = _objects(target['applicationEvidence'])
        .where((e) => e['applicationId'] == applicationId)
        .toList();
    final evidence = records.length == 1 ? records.single : <String, dynamic>{};
    final matched = evidence.isEmpty ||
        (evidence['deviceId'] == target['deviceId'] &&
            evidence['registrationId'] == target['registrationId']);
    final now = DateTime.now().millisecondsSinceEpoch;
    final reported = _timestamp(evidence['reportedAt']);
    final retrieved = _timestamp(evidence['retrievedAt']);
    final expires = _timestamp(evidence['expiresAt']);
    var state = evidence['state'];
    if (state == 'VERIFIED_IDENTITY') {
      if (expires != null && expires <= now) {
        state = 'STALE';
      } else if (reported == null ||
          retrieved == null ||
          expires == null ||
          reported > retrieved ||
          retrieved > now ||
          expires <= retrieved) {
        state = 'UNKNOWN';
      }
    }
    final reason = evidence['reasonCode'];
    final (status, next) = !matched
        ? ('应用核验记录与当前设备不匹配', '请重新核验当前设备后预览。')
        : records.length > 1
            ? ('应用核验状态待确认', '核验记录存在冲突，请重新核验。')
            : switch (state) {
                'VERIFIED_IDENTITY' => ('应用身份已核验', '系统控制尚未确认'),
                'PENDING' => ('正在核验', '请稍后重新预览。'),
                'WAITING_REPORT' => ('等待设备报告', '请在设备报告更新后重新预览。'),
                'STALE' => ('核验结果已过期或设备信息已变化', '请重新核验后预览。'),
                'REJECTED' => ('应用信息未通过核验', '请检查应用声明与设备报告。'),
                'FAILED' => ('暂时无法读取报告', '请到设备应用核验页面查看允许重试时间。'),
                'UNAVAILABLE' when reason == 'MANAGED_BINDING_REQUIRED' => (
                    '此设备尚未完成受管绑定',
                    '完成设备绑定后重新预览'
                  ),
                'UNAVAILABLE'
                    when reason == 'MANAGED_APPLICATION_ADMIN_REQUIRED' =>
                  ('需要机构管理员核验', '请联系机构管理员完成核验后重新预览'),
                'UNAVAILABLE' => ('暂时无法核验此设备上的应用', '请到设备应用核验页面查看当前条件。'),
                'ABSENT' || null when evidence.isEmpty || state == 'ABSENT' => (
                    '尚未核验此设备上的应用',
                    '请先完成此设备的应用核验。'
                  ),
                _ => ('应用核验状态待确认', '请重新核验后预览。'),
              };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: const TextStyle(fontWeight: FontWeight.w500)),
        Text(status),
        Text(next, style: const TextStyle(color: muted, fontSize: 12)),
        if (next != '系统控制尚未确认')
          const Text('系统控制尚未确认', style: TextStyle(color: muted, fontSize: 12)),
        if (matched && state == 'VERIFIED_IDENTITY') ...[
          Text('报告时间 ${_date(reported)}',
              style: const TextStyle(color: muted, fontSize: 12)),
          Text('核验时间 ${_date(retrieved)}',
              style: const TextStyle(color: muted, fontSize: 12)),
          Text('核验有效至 ${_date(expires)}',
              style: const TextStyle(color: muted, fontSize: 12)),
        ],
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill(this.text, this.color);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
            color: color.withOpacity(.07),
            borderRadius: BorderRadius.circular(6)),
        child: Text(text,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w500)),
      );
}

List<Json> _objects(dynamic value) =>
    value is List ? value.whereType<Json>().toList() : const [];
int? _timestamp(dynamic value) =>
    value is int && value > 0 && value < 8640000000000000 ? value : null;
String _date(int? value) => value == null ? '时间未提供' : dateLabel(value);
int _bucket(dynamic state) => switch (state) {
      'SUPPORTED_PENDING' => 0,
      'UNSUPPORTED' || 'UNAVAILABLE' => 1,
      _ => 2,
    };
String _ruleStatus(dynamic state) => switch (state) {
      'SUPPORTED_PENDING' => '支持条件满足 · 尚未执行',
      'UNSUPPORTED' => '当前条件受限',
      'UNAVAILABLE' => '核验暂不可用',
      'UNKNOWN' || 'UNVERIFIED' => '待核验',
      'STALE' => '检查信息已过期',
      _ => '检查状态待确认',
    };
String _observation(dynamic state) => switch (state) {
      'RECENT' => '最近已上报',
      'STALE' => '上报已过期',
      _ => '尚无近期可信上报',
    };
String _kind(dynamic kind) => switch (kind) {
      'APP_LAUNCH' => '应用启动',
      'APP_INSTALL' => '应用安装',
      'APP_UNINSTALL' => '应用卸载',
      'RUNTIME_PERMISSION' => '应用权限',
      'SPECIAL_ACCESS' => '特殊访问权限',
      'DOMAIN_ACCESS' => '域名访问',
      'DAILY_QUOTA' => '每日使用时长',
      'TIME_WINDOW' => '使用时段',
      'USAGE_REMINDER' => '使用提醒',
      _ => '规则检查',
    };
String _reason(dynamic reason) => switch (reason) {
      'EVIDENCE_NOT_CERTIFIED' => '设备自报信息尚未认证，请完成可信能力核验。',
      'CAPABILITY_NOT_VERIFIED' => '此设备的相关能力尚未核验。',
      'MANAGED_REGISTRATION_REQUIRED' => '请先完成受管设备注册和执行连接配置。',
      'ENFORCEMENT_ADAPTER_UNAVAILABLE' ||
      'DELIVERY_ADAPTER_NOT_CONFIGURED' =>
        '系统执行连接尚未配置。',
      'AUTO_GRANT_NOT_AVAILABLE' => '当前不支持自动授予应用权限。',
      'SYSTEM_USER_ACTION_REQUIRED' => '需要设备用户在本机确认权限。',
      'AWAITING_EXECUTION' => '此结果只说明检查条件，尚无设备执行回执。',
      'APPLICATION_PLATFORM_MISMATCH' => '应用声明与设备平台不一致。',
      'APPLICATION_PROFILE_NOT_VERIFIED' => '尚未确认应用所在的设备空间。',
      'APPLICATION_IDENTITY_NOT_VERIFIED' => '尚未核验此设备上的应用身份。',
      'DEVICE_NOT_ACTIVE' => '此设备注册已失效，请核对当前设备注册。',
      'SAME_LAYER_CONFLICT_RESTRICTIVE_WINS' => '规则存在冲突，预览采用限制更严格的配置。',
      'SMALLER_QUOTA_WINS' => '多条时长规则重叠，预览采用较短时长。',
      'INSTALL_DENY_MAY_REMOVE_EXISTING_APP' => '禁止安装可能移除已安装的应用，保存前请核对配置。',
      'APPLICATION_EVIDENCE_MISSING' => '缺少此设备的应用核验记录。',
      'PROTECTED_PACKAGE' => '此应用属于受保护的系统组件。',
      null => '请查看此设备的能力和核验记录。',
      _ => '此项限制原因需要进一步核验，请联系管理员。',
    };

String _effect(dynamic effect) => switch (effect) {
      'ALLOW' => '允许',
      'DENY' => '禁止',
      'GRANT' => '授予',
      'DEFAULT' => '系统默认',
      'PROTECT' => '保护',
      'LIMIT' => '限制',
      'REMIND' => '提醒',
      _ => '尚未明确',
    };
