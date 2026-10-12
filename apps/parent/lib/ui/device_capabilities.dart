import 'package:flutter/material.dart';

import '../core/parent_api.dart';
import '../core/parent_session.dart';

/// Reads the server's scoped capability projection. Agent observations are
/// never presented as proof that a policy was enforced by Android.
Future<void> showDeviceCapabilities(
    BuildContext context, ParentSession session, String deviceId) {
  return showDialog<void>(
    context: context,
    builder: (_) => _DeviceCapabilities(session: session, deviceId: deviceId),
  );
}

class _DeviceCapabilities extends StatefulWidget {
  final ParentSession session;
  final String deviceId;
  const _DeviceCapabilities({required this.session, required this.deviceId});

  @override
  State<_DeviceCapabilities> createState() => _DeviceCapabilitiesState();
}

class _DeviceCapabilitiesState extends State<_DeviceCapabilities> {
  late final String tenantId;
  late final String actor;
  late final String role;
  late Future<(Json, List<Json>)> result;

  @override
  void initState() {
    super.initState();
    tenantId = widget.session.tenant!['id'] as String;
    actor = widget.session.profile!['subject'] as String;
    role = widget.session.role;
    widget.session.addListener(_closeIfScopeChanged);
    result = _read('/tenants/$tenantId/devices/${widget.deviceId}');
  }

  void _closeIfScopeChanged() {
    if (!mounted) return;
    if (!widget.session.authenticated ||
        widget.session.tenant?['id'] != tenantId ||
        widget.session.profile?['subject'] != actor ||
        widget.session.role != role) {
      Navigator.of(context).pop();
    }
  }

  void _reload() {
    final root = '/tenants/$tenantId/devices/${widget.deviceId}';
    setState(() => result = _read(root));
  }

  Future<(Json, List<Json>)> _read(String root) async {
    final (device, capabilities) = await (
      widget.session.api.object(root),
      widget.session.api.object('$root/capabilities'),
    ).wait;
    if (device['id'] != widget.deviceId || capabilities['items'] is! List) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    final items = <Json>[];
    for (final raw in capabilities['items'] as List) {
      if (raw is! Json ||
          raw['key'] is! String ||
          raw['status'] is! String ||
          raw['limitationCode'] is! String ||
          raw['grantStatus'] is! String ||
          raw['evidenceSource'] is! String ||
          raw['reportedSupported'] is! bool ||
          raw['effectiveSupported'] is! bool) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      items.add(raw);
    }
    return (device, items);
  }

  @override
  void dispose() {
    widget.session.removeListener(_closeIfScopeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: height * .84),
        child: FutureBuilder<(Json, List<Json>)>(
          future: result,
          builder: (context, snapshot) => ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(22),
            children: [
              Row(children: [
                const Icon(Icons.verified_user_outlined,
                    color: Color(0xFF315E86)),
                const SizedBox(width: 10),
                Expanded(
                    child: Text('设备能力',
                        style: Theme.of(context).textTheme.titleLarge)),
                IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close)),
              ]),
              const SizedBox(height: 10),
              if (snapshot.hasError) ...[
                Text('${snapshot.error}',
                    style: const TextStyle(color: Color(0xFF9A3931))),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新加载')),
              ] else if (snapshot.connectionState != ConnectionState.done)
                const Padding(
                    padding: EdgeInsets.all(28),
                    child: Center(child: CircularProgressIndicator()))
              else
                ..._content(snapshot.data!.$1, snapshot.data!.$2),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _content(Json device, List<Json> items) {
    final usable =
        items.where((item) => item['effectiveSupported'] == true).length;
    return [
      Text(device['displayName'] as String? ?? '未命名设备',
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 6),
      Text(
          '${_mode(device['managementMode'])} · ${_observation(device['observationStatus'])} · 最近连接 ${_time(device['lastHeartbeatAt'])}',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 14),
      DecoratedBox(
        decoration: BoxDecoration(
            color: const Color(0xFFEAF2F8),
            borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(usable == 0
              ? '当前没有经服务端确认可用于系统执行的能力。设备自报支持或最近连线，都不等于应用限制已生效。'
              : '服务端确认 $usable 项能力可用。具体规则是否已执行，还需查看策略执行回执。'),
        ),
      ),
      const SizedBox(height: 18),
      Text('逐项能力 · ${items.length}',
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      if (items.isEmpty) const Text('尚无能力记录。请检查设备注册和最近连接。'),
      for (final item in items) ...[
        _CapabilityCard(item),
        const SizedBox(height: 9),
      ],
    ];
  }
}

class _CapabilityCard extends StatelessWidget {
  final Json item;
  const _CapabilityCard(this.item);

  @override
  Widget build(BuildContext context) {
    final usable = item['effectiveSupported'] == true;
    final key = item['key'] as String;
    return Semantics(
      container: true,
      label:
          '${_names[key] ?? key}，${usable ? '服务端确认可用' : _status(item['status'])}',
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: usable ? const Color(0xFFEAF7F2) : const Color(0xFFF5F7F7),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFDDE4E9)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(usable ? Icons.verified_outlined : Icons.info_outline,
                color:
                    usable ? const Color(0xFF13745C) : const Color(0xFF315E86)),
            const SizedBox(width: 8),
            Expanded(
                child: Text(_names[key] ?? '其他能力',
                    style: Theme.of(context).textTheme.titleSmall)),
            Text(_status(item['status'])),
          ]),
          const SizedBox(height: 5),
          SelectableText(key, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 7),
          Text('限制：${_limitation(item['limitationCode'])}'),
          Text(
              '授权：${_grant(item['grantStatus'])} · ${item['reportedSupported'] == true ? '设备自报支持' : '设备未报告支持'}'),
          Text(
              '来源：${_source(item['evidenceSource'])} · 核对 ${_time(item['checkedAt'])}'),
        ]),
      ),
    );
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

String _mode(Object? value) => switch (value) {
      'BYOD' => '个人设备',
      'UNVERIFIED' => '未确认模式',
      'FULLY_MANAGED' => '完全受管设备',
      'DEDICATED' => '专用受管设备',
      _ => '管理模式未知',
    };

String _observation(Object? value) => switch (value) {
      'RECENT' => '最近有连接',
      'STALE' => '连接记录已过期',
      'REVOKED' => '已撤销',
      _ => '连接状态未知',
    };

String _status(Object? value) => switch (value) {
      'SUPPORTED' => '服务端确认可用',
      'UNSUPPORTED' => '不可用',
      'STALE' => '证据过期',
      'UNVERIFIED' => '未经核实',
      _ => '未知',
    };

String _limitation(Object? value) => switch (value) {
      'MANAGED_REGISTRATION_REQUIRED' => '需要受管设备注册',
      'EVIDENCE_NOT_CERTIFIED' => '设备自报尚未经过系统能力认证',
      _ => value is String && value.isNotEmpty ? value : '原因未知',
    };

String _grant(Object? value) => switch (value) {
      'GRANTED' => '设备报告已授权',
      'DENIED' => '设备报告未授权',
      'NOT_REQUESTED' => '未请求',
      _ => '状态未知',
    };

String _source(Object? value) => switch (value) {
      'AGENT_REPORT' => '设备自报',
      'REGISTRATION_MODE' => '注册模式',
      _ => '来源未知',
    };

String _time(Object? milliseconds) {
  if (milliseconds is! int) return '时间未知';
  final value = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}
