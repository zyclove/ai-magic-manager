import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/session.dart';
import '../ui/design.dart';

/// Render only the server's scoped capability projection. Agent reports are
/// observations and must never be presented as proof that a rule was enforced.
Future<void> showDeviceCapabilitiesDialog(
    BuildContext context, Session session, Json device, Json response) async {
  final tenantId = session.tenant?['id'];
  if (tenantId is! String ||
      device['id'] is! String ||
      response['items'] is! List) {
    throw const ApiFailure(502, 'CAPABILITY_RESPONSE_INVALID');
  }
  final items = <_Capability>[];
  for (final raw in response['items'] as List) {
    if (raw is! Map<String, dynamic>) {
      throw const ApiFailure(502, 'CAPABILITY_RESPONSE_INVALID');
    }
    items.add(_Capability.fromJson(raw));
  }
  if (!context.mounted || session.tenant?['id'] != tenantId) return;
  await showDialog<void>(
      context: context,
      builder: (_) => _DeviceCapabilitiesDialog(
          session: session,
          tenantId: tenantId,
          role: session.role,
          deviceName: device['displayName'] as String? ?? '设备',
          mode: device['managementMode'] as String? ?? 'UNKNOWN',
          items: items));
}

class _Capability {
  final String key, status, grantStatus, evidenceSource, limitationCode;
  final bool reportedSupported, effectiveSupported;
  final Object? checkedAt;

  const _Capability(
      this.key,
      this.status,
      this.grantStatus,
      this.evidenceSource,
      this.limitationCode,
      this.reportedSupported,
      this.effectiveSupported,
      this.checkedAt);

  factory _Capability.fromJson(Json json) {
    final key = json['key'],
        status = json['status'],
        grant = json['grantStatus'],
        source = json['evidenceSource'],
        reason = json['limitationCode'],
        reported = json['reportedSupported'],
        effective = json['effectiveSupported'];
    if (key is! String ||
        key.isEmpty ||
        key.length > 100 ||
        status is! String ||
        grant is! String ||
        source is! String ||
        reason is! String ||
        reported is! bool ||
        effective is! bool) {
      throw const ApiFailure(502, 'CAPABILITY_RESPONSE_INVALID');
    }
    return _Capability(key, status, grant, source, reason, reported, effective,
        json['checkedAt']);
  }
}

const _names = <String, String>{
  'managed.app_policy': '受管应用策略',
  'app.install_policy': '应用安装限制',
  'app.launch_block': '阻止应用启动',
  'permission.runtime': '运行时权限管理',
  'device.lock_task': '专用设备锁定',
  'usage.shared_quota_enforced': '共享额度执行',
  'usage.report': '使用情况报告',
  'network.domain_filter': '域名过滤',
};

class _DeviceCapabilitiesDialog extends StatefulWidget {
  final Session session;
  final String tenantId, role, deviceName, mode;
  final List<_Capability> items;
  const _DeviceCapabilitiesDialog(
      {required this.session,
      required this.tenantId,
      required this.role,
      required this.deviceName,
      required this.mode,
      required this.items});

  @override
  State<_DeviceCapabilitiesDialog> createState() =>
      _DeviceCapabilitiesDialogState();
}

class _DeviceCapabilitiesDialogState extends State<_DeviceCapabilitiesDialog> {
  bool _dismissed = false;
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_scopeChanged);
  }

  void _scopeChanged() {
    if (!_dismissed &&
        mounted &&
        (widget.session.tenant?['id'] != widget.tenantId ||
            widget.session.role != widget.role ||
            !widget.session.authenticated)) {
      _dismissed = true;
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_scopeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final supported =
        widget.items.where((item) => item.effectiveSupported).length;
    return Dialog(
        child: ConstrainedBox(
            constraints:
                BoxConstraints(maxWidth: 720, maxHeight: size.height * .84),
            child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    const Icon(Icons.shield_outlined, color: navy, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Text('设备能力 · ${widget.deviceName}',
                            style: Theme.of(context).textTheme.titleLarge)),
                    IconButton(
                        tooltip: '关闭设备能力',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close))
                  ]),
                  const SizedBox(height: 16),
                  Notice(
                      supported == 0
                          ? '当前没有经服务端确认可用于系统执行的能力。设备自报已授权，也不代表应用阻止或额度限制已生效。'
                          : '服务端确认 $supported 项能力可用。具体规则是否已执行，仍须查看对应策略的执行回执。',
                      warning: supported == 0),
                  const SizedBox(height: 12),
                  Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                          '管理模式：${label(widget.mode)} · 能力 ${widget.items.length} 项',
                          style: Theme.of(context).textTheme.bodySmall)),
                  const SizedBox(height: 12),
                  Flexible(
                      child: widget.items.isEmpty
                          ? const Center(child: Text('尚无能力记录。请检查设备注册与最近心跳。'))
                          : ListView.separated(
                              shrinkWrap: true,
                              itemCount: widget.items.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (_, index) =>
                                  _CapabilityCard(widget.items[index])))
                ]))));
  }
}

class _CapabilityCard extends StatelessWidget {
  final _Capability item;
  const _CapabilityCard(this.item);

  @override
  Widget build(BuildContext context) {
    final usable = item.effectiveSupported;
    return Semantics(
        container: true,
        label:
            '${_names[item.key] ?? '其他能力'}，${usable ? '服务端确认可用' : label(item.status)}',
        child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: usable ? const Color(0xFFEAF7F2) : canvas,
                border: Border.all(color: line),
                borderRadius: BorderRadius.circular(10)),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(usable ? Icons.verified_outlined : Icons.info_outline,
                    color: usable ? const Color(0xFF00886C) : muted),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(_names[item.key] ?? '其他能力',
                        style: Theme.of(context).textTheme.titleMedium)),
                StatusTag(item.status)
              ]),
              const SizedBox(height: 6),
              SelectableText(item.key,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              Text('限制：${label(item.limitationCode)}'),
              Text(
                  '授权：${label(item.grantStatus)} · ${item.reportedSupported ? '设备自报支持' : '设备未报告支持'}'),
              Text(
                  '证据：${item.evidenceSource == 'AGENT_REPORT' ? '设备自报' : item.evidenceSource == 'REGISTRATION_MODE' ? '注册模式' : label(item.evidenceSource)} · 核对时间：${dateLabel(item.checkedAt)}')
            ])));
  }
}
