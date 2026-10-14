import 'dart:async';
import 'package:flutter/material.dart';

import '../core/parent_api.dart';
import '../core/parent_session.dart';
import '../core/permission_observation.dart' show permissionObservationEnabled;
import 'permission_observation_page.dart';

/// Reads the server's scoped capability projection. Agent observations are
/// never presented as proof that a policy was enforced by Android.
Future<void> showDeviceCapabilities(
    BuildContext context, ParentSession session, String deviceId) {
  if (!session.authenticated ||
      session.tenant == null ||
      session.profile == null) {
    return Future.value();
  }
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

class _DeviceCapabilitiesState extends State<_DeviceCapabilities>
    with WidgetsBindingObserver {
  late final String tenantId;
  late final String actor;
  late final String role;
  late Future<(Json, List<Json>)> result;
  bool foreground = true;
  int generation = 0;
  _CapabilityFilter filter = _CapabilityFilter.all;
  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.tenant?['id'] == tenantId &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;

  @override
  void initState() {
    super.initState();
    tenantId = widget.session.tenant!['id'] as String;
    actor = widget.session.profile!['subject'] as String;
    role = widget.session.role;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(_closeIfScopeChanged);
    result = _read('/tenants/$tenantId/devices/${widget.deviceId}');
  }

  void _closeIfScopeChanged() {
    if (!mounted) return;
    if (!current) {
      generation++;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || current) return;
        final route = ModalRoute.of(context);
        if (route != null && route.isActive) {
          Navigator.of(context).removeRoute(route);
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  void _reload() {
    if (!current || !foreground) return;
    final root = '/tenants/$tenantId/devices/${widget.deviceId}';
    setState(() {
      result = _read(root);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    generation++;
    if (mounted) setState(() {});
    if (foreground && current) _reload();
  }

  Future<(Json, List<Json>)> _read(String root) async {
    final epoch = ++generation;
    bool valid() => current && foreground && generation == epoch;
    final (device, capabilities) = await (
      widget.session.api.object(root, isCurrent: valid),
      widget.session.api.object('$root/capabilities', isCurrent: valid),
    ).wait;
    if (!valid()) throw const ParentApiException(409, 'SCOPE_DENIED');
    if (device['id'] != widget.deviceId ||
        device['displayName'] is! String ||
        capabilities['items'] is! List ||
        (capabilities['items'] as List).length > 128) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    final items = <Json>[];
    final keys = <String>{};
    for (final raw in capabilities['items'] as List) {
      if (raw is! Json ||
          raw['key'] is! String ||
          raw['status'] is! String ||
          raw['limitationCode'] is! String ||
          raw['grantStatus'] is! String ||
          raw['evidenceSource'] is! String ||
          raw['reportedSupported'] is! bool ||
          raw['effectiveSupported'] is! bool ||
          !RegExp(r'^[a-z][a-z0-9_.]{1,63}$').hasMatch(raw['key']) ||
          !keys.add(raw['key']) ||
          (raw['checkedAt'] != null &&
              (raw['checkedAt'] is! int ||
                  raw['checkedAt'] < 0 ||
                  raw['checkedAt'] > 8640000000000000))) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      items.add(raw);
    }
    // Contradictory evidence must never produce a green availability badge.
    if (items.any((item) =>
        item['effectiveSupported'] == true && item['status'] != 'SUPPORTED')) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return (device, items);
  }

  @override
  void dispose() {
    widget.session.removeListener(_closeIfScopeChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!current || !foreground) {
      return const Dialog(
          child: Padding(padding: EdgeInsets.all(24), child: Text('设备信息已隐藏。')));
    }
    final height = MediaQuery.sizeOf(context).height;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: height * .84),
        child: FutureBuilder<(Json, List<Json>)>(
          future: result,
          builder: (context, snapshot) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                  child: Row(children: [
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
                  ])),
              const Divider(height: 1),
              Flexible(
                  child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.all(20),
                      children: [
                    if (snapshot.hasError) ...[
                      const Icon(Icons.cloud_off_outlined, size: 32),
                      const SizedBox(height: 12),
                      Text('暂时无法读取设备能力',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(_readError(snapshot.error),
                          style: const TextStyle(color: Color(0xFF9A3931))),
                    ] else if (snapshot.connectionState != ConnectionState.done)
                      const Padding(
                          padding: EdgeInsets.all(28),
                          child: Center(child: CircularProgressIndicator()))
                    else
                      ..._content(snapshot.data!.$1, snapshot.data!.$2),
                  ])),
              const Divider(height: 1),
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed:
                          snapshot.connectionState == ConnectionState.done
                              ? _reload
                              : null,
                      icon: const Icon(Icons.refresh),
                      label: Text(snapshot.hasError ? '重新加载' : '刷新状态'),
                    ),
                  )),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _content(Json device, List<Json> items) {
    final usable =
        items.where((item) => item['effectiveSupported'] == true).length;
    final visible = items
        .where((item) => switch (filter) {
              _CapabilityFilter.all => true,
              _CapabilityFilter.available => item['effectiveSupported'] == true,
              _CapabilityFilter.attention => item['effectiveSupported'] != true,
            })
        .toList();
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
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('当前可确认 $usable 项能力',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(usable == 0
                ? '暂不能确认系统限制可执行。设备在线或自报支持，不代表规则已生效。'
                : '能力可用不代表规则已执行；执行结果请查看策略回执。'),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      Text('下一步', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 4),
      Text(_nextStep(device, items)),
      const SizedBox(height: 18),
      if (permissionObservationEnabled &&
          widget.session.canDecide &&
          device['state'] == 'ACTIVE' &&
          const {'ANDROID', 'ANDROID_TV'}.contains(device['platform']))
        FilledButton.tonalIcon(
            onPressed: () =>
                openParentPermissions(context, widget.session, device),
            icon: const Icon(Icons.privacy_tip_outlined),
            label: const Text('查看应用权限')),
      const SizedBox(height: 12),
      Text('逐项能力', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 4, children: [
        for (final option in _CapabilityFilter.values)
          ChoiceChip(
            label: Text(switch (option) {
              _CapabilityFilter.all => '全部 ${items.length}',
              _CapabilityFilter.available => '可用 $usable',
              _CapabilityFilter.attention => '待确认 ${items.length - usable}',
            }),
            selected: filter == option,
            onSelected: (_) => setState(() => filter = option),
          ),
      ]),
      const SizedBox(height: 12),
      if (items.isEmpty) const Text('尚无能力记录。请检查设备注册和最近连接。'),
      if (items.isNotEmpty && visible.isEmpty)
        Text(filter == _CapabilityFilter.available
            ? '暂无可用能力。切换“待确认”查看原因。'
            : '没有待确认的能力。规则执行结果仍需查看策略回执。'),
      for (final item in visible) ...[
        _CapabilityCard(item, key: ValueKey(item['key'])),
        const SizedBox(height: 9),
      ],
    ];
  }
}

class _CapabilityCard extends StatelessWidget {
  final Json item;
  const _CapabilityCard(this.item, {super.key});

  @override
  Widget build(BuildContext context) {
    final usable = item['effectiveSupported'] == true;
    final key = item['key'] as String;
    return Semantics(
      container: true,
      label: '${_names[key] ?? '其他能力'}，${_availability(item)}',
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
          ]),
          const SizedBox(height: 8),
          Text(_availability(item),
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: usable
                      ? const Color(0xFF13745C)
                      : const Color(0xFF315E86))),
          const SizedBox(height: 4),
          Text(usable
              ? '查看策略回执，确认具体规则是否已执行。'
              : _limitation(item['limitationCode'])),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            title: const Text('查看依据', style: TextStyle(fontSize: 14)),
            children: [
              SelectableText('能力标识：$key',
                  style: Theme.of(context).textTheme.bodySmall),
              Text('授权：${_grant(item['grantStatus'])}'),
              Text(item['reportedSupported'] == true ? '设备自报支持' : '设备未报告支持'),
              Text('来源：${_source(item['evidenceSource'])}'),
              Text('核对时间：${_time(item['checkedAt'])}'),
              if (item['limitationCode'] != '')
                SelectableText('原因编号：${item['limitationCode']}'),
            ],
          ),
        ]),
      ),
    );
  }
}

enum _CapabilityFilter { all, available, attention }

String _availability(Json item) => item['effectiveSupported'] == true
    ? '服务端确认可用'
    : item['status'] == 'SUPPORTED'
        ? '尚未确认可用'
        : _status(item['status']);

/// Suggest only actions supported by the current evidence. Refreshing never
/// upgrades a BYOD device or authorizes another data collection purpose.
String _nextStep(Json device, List<Json> items) {
  if (device['state'] != 'ACTIVE' || device['observationStatus'] == 'REVOKED') {
    return '设备已停用或撤销，请返回设备列表核对注册状态。';
  }
  if (device['observationStatus'] != 'RECENT') {
    return '请先让儿童设备联网并打开智能管家，再刷新状态。';
  }
  if (items.any((item) => item['status'] == 'STALE')) {
    return '部分能力记录已过期，请在儿童设备重新上报后刷新。';
  }
  if (items.any(
      (item) => item['limitationCode'] == 'MANAGED_REGISTRATION_REQUIRED')) {
    return '需要阻止应用启动？请联系管理员确认受管接入条件；普通个人设备可能不支持。';
  }
  return '选择下方能力查看说明；需要核对来源时展开“查看依据”。';
}

String _readError(Object? error) {
  if (error is ParentApiException) return error.toString();
  // Tuple.wait wraps errors; keep useful API messages without exposing internals.
  if (error is ParallelWaitError) {
    final errors = error.errors;
    if (errors is (AsyncError?, AsyncError?)) {
      return _readError(errors.$1?.error ?? errors.$2?.error);
    }
  }
  return '读取未完成，请稍后重新加载。';
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
      _ => '尚无明确说明，请展开依据并联系管理员核对。',
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
  if (milliseconds is! int ||
      milliseconds < 0 ||
      milliseconds > 8640000000000000) return '时间未知';
  final value = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}
