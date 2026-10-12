import 'package:device_policy/device_policy.dart';
import 'package:flutter/material.dart';
import 'design.dart';

/// Read-only explanation of a signed CONFIGURE_ONLY document. These labels
/// describe administrator intent and capability evidence, never OS execution.
class ChildPolicyExplanation extends StatefulWidget {
  final VerifiedConfiguration configuration;
  const ChildPolicyExplanation({super.key, required this.configuration});

  @override
  State<ChildPolicyExplanation> createState() => _ChildPolicyExplanationState();
}

class _ChildPolicyExplanationState extends State<ChildPolicyExplanation> {
  int _visible = 8;

  @override
  void didUpdateWidget(covariant ChildPolicyExplanation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configuration.versionId != widget.configuration.versionId) {
      _visible = 8;
    }
  }

  String _text(Object? value, String fallback) {
    if (value is! String) return fallback;
    final clean = value
        .replaceAll(RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]'), ' ')
        .trim();
    return clean.isEmpty ? fallback : clean;
  }

  String? _code(Object? value) => value is String ? value : null;

  Map<String, String> _names(Object? entries, String fallback) {
    final names = <String, String>{};
    if (entries is! List) return names;
    for (final item in entries) {
      if (item is! Map || item['id'] is! String) continue;
      names[item['id'] as String] =
          _text(item['displayName'] ?? item['name'], fallback);
    }
    return names;
  }

  String _kind(String? kind) => switch (kind) {
        'APP_LAUNCH' => '打开应用',
        'APP_INSTALL' => '安装应用',
        'APP_UNINSTALL' => '卸载保护',
        'RUNTIME_PERMISSION' => '系统权限',
        'SPECIAL_ACCESS' => '特殊访问',
        'DAILY_QUOTA' => '每日额度',
        'USAGE_REMINDER' => '使用提醒',
        'TIME_WINDOW' => '可用时段',
        'DOMAIN_ACCESS' => '网站访问',
        _ => '其他规则'
      };

  String _effect(String? effect) => switch (effect) {
        'ALLOW' => '计划允许',
        'DENY' => '计划限制',
        'DEFAULT' => '使用系统默认设置',
        'GRANT' => '计划授权',
        'PROTECT' => '计划保护',
        'LIMIT' => '计划限额',
        'REMIND' => '计划提醒',
        _ => '规则意图待核对'
      };

  String _status(String? status) => switch (status) {
        'SUPPORTED_PENDING' => '设备能力待执行验证',
        'UNVERIFIED' => '应用或设备身份待核对',
        'UNSUPPORTED' => '当前不支持执行',
        'UNAVAILABLE' => '设备暂不可用',
        'STALE' => '设备能力信息已过期',
        'UNKNOWN' => '设备能力尚未核对',
        _ => '设备执行状态待核对'
      };

  String _reason(String? code) => switch (code) {
        'MANAGED_REGISTRATION_REQUIRED' => '需要经审核的受管设备注册。',
        'APPLICATION_IDENTITY_NOT_VERIFIED' => '尚未核实设备上安装的应用身份。',
        'APPLICATION_PLATFORM_MISMATCH' => '此应用与设备平台不匹配。',
        'APPLICATION_PROFILE_NOT_VERIFIED' => '此应用不在已核实的主用户空间。',
        'DEVICE_NOT_ACTIVE' => '设备连接状态需要重新确认。',
        'EVIDENCE_NOT_CERTIFIED' ||
        'CAPABILITY_NOT_VERIFIED' =>
          '目前没有可证明此规则已执行的系统证据。',
        'AWAITING_EXECUTION' => '等待独立的设备执行回执。',
        'AUTO_GRANT_NOT_AVAILABLE' => '当前不会自动授予其他应用的系统权限。',
        'SYSTEM_USER_ACTION_REQUIRED' => '此特殊访问需要在设备上由用户单独操作。',
        _ => '请监护人检查设备能力和规则状态。'
      };

  String _target(
      Map rule, Map<String, String> apps, Map<String, String> schedules) {
    final kind = rule['kind'];
    if (kind == 'DOMAIN_ACCESS') return _text(rule['domain'], '网站待核对');
    final appId = rule['applicationId'];
    final app = appId is String ? apps[appId] : null;
    if (app != null) return app;
    final scheduleId = rule['scheduleId'];
    if (scheduleId is String && schedules.containsKey(scheduleId)) {
      return schedules[scheduleId]!;
    }
    return appId == null ? '设备使用安排' : '应用身份待核对';
  }

  String? _detail(Map rule, Map<String, String> schedules) {
    final parts = <String>[];
    if (rule['seconds'] is int && (rule['seconds'] as int) > 0) {
      final seconds = rule['seconds'] as int;
      parts.add(seconds % 60 == 0 ? '${seconds ~/ 60} 分钟' : '$seconds 秒');
    }
    if (rule['scheduleId'] is String) {
      parts.add('时段：${schedules[rule['scheduleId']] ?? '安排待核对'}');
    }
    if (rule['permission'] is String) {
      final permission = _text(rule['permission'], '权限待核对');
      parts.add('权限：${permission.replaceFirst('android.permission.', '')}');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  void _showDetails(BuildContext context, Map rule, Map<String, String> apps,
      Map<String, String> schedules) {
    showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(_kind(_code(rule['kind']))),
              content: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(_target(rule, apps, schedules),
                        style: Theme.of(context).textTheme.titleMedium),
                    if (_detail(rule, schedules) case final detail?) ...[
                      const SizedBox(height: 12),
                      Text(detail)
                    ],
                    const SizedBox(height: 16),
                    Text(_effect(_code(rule['predictedEffect']))),
                    const SizedBox(height: 8),
                    Text(_status(_code(rule['status']))),
                    const SizedBox(height: 8),
                    Text(_reason(_code(rule['reasonCode']))),
                    if (rule['kind'] == 'DOMAIN_ACCESS') ...[
                      const SizedBox(height: 12),
                      const Text('此规则只指向列出的域名。当前没有全设备网站过滤，其他应用、子域名及加密网页内容未被此配置自动限制。')
                    ],
                    const SizedBox(height: 16),
                    const Text('这是已保存的监护规则意图。当前设备端不能据此阻止其他应用。')
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('知道了'))
              ],
            ));
  }

  @override
  Widget build(BuildContext context) {
    final document = widget.configuration.document;
    final rawRules = document?['rules'];
    final rules =
        rawRules is List ? rawRules.whereType<Map>().toList() : <Map>[];
    final apps = _names(document?['applications'], '未命名应用');
    final schedules = _names(document?['schedules'], '未命名时段');
    return ExpansionTile(
        key: PageStorageKey(widget.configuration.policyId),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 20),
        title: Text(_text(document?['name'], '已保存的监护规则'),
            maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text('${rules.length} 条规则 · 已验签保存，当前不执行跨应用限制'),
        children: [
          const ChildNotice('这里展示监护人设置的规则意图',
              detail: '当前设备端未实现跨应用系统限制；看到“计划限制”不表示其他应用已被阻止。'),
          if (rules.isEmpty)
            const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text('这份配置没有可展示的规则。')),
          for (final rule in rules.take(_visible))
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                            alignment: Alignment.centerLeft,
                            backgroundColor: childSoft,
                            padding: const EdgeInsets.all(16),
                            side: const BorderSide(color: childLine)),
                        onPressed: () =>
                            _showDetails(context, rule, apps, schedules),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_kind(_code(rule['kind'])),
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 6),
                              Text(_target(rule, apps, schedules),
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                              if (_detail(rule, schedules)
                                  case final detail?) ...[
                                const SizedBox(height: 6),
                                Text(detail,
                                    style:
                                        Theme.of(context).textTheme.bodyMedium)
                              ],
                              const SizedBox(height: 10),
                              Text(
                                  '${_effect(_code(rule['predictedEffect']))} · ${_status(_code(rule['status']))}',
                                  style: const TextStyle(
                                      color: childNavy,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              Text(_reason(_code(rule['reasonCode'])),
                                  style: Theme.of(context).textTheme.bodyMedium)
                            ])))),
          if (rules.length > _visible)
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child: TextButton(
                    onPressed: () => setState(() => _visible += 8),
                    child: const Text('显示更多规则')))
        ]);
  }
}
