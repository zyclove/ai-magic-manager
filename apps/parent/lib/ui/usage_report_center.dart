import 'package:flutter/material.dart';
import 'package:usage_reporting/usage_reporting.dart';
import 'package:usage_report_ui/usage_report_ui.dart';
import '../core/paged_collection.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import '../core/usage_reports.dart';
import 'observation_settings_page.dart';

/// Parent reports expose only server-authorized activity; directory visibility is not consent.
class UsageReportCenter extends StatefulWidget {
  final ParentSession session;
  const UsageReportCenter({super.key, required this.session});
  @override
  State<UsageReportCenter> createState() => _UsageReportCenterState();
}

class _UsageReportCenterState extends State<UsageReportCenter> {
  late final String tenant, actor, role;
  late final PagedCollection devices;
  bool opening = false;
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
    tenant = widget.session.tenant!['id'];
    actor = widget.session.profile!['subject'];
    role = widget.session.role;
    devices = PagedCollection(widget.session.api, '/tenants/$tenant/devices');
    widget.session.addListener(_changed);
  }

  void _changed() {
    if (!mounted || current) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    devices.dispose();
    super.dispose();
  }

  Future<void> _open(Json device) async {
    if (!current || opening) return;
    if (['id', 'registrationId', 'subjectId', 'displayName', 'platform']
        .any((k) => device[k] is! String)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('设备信息不完整，请刷新。')));
      return;
    }
    final target = UsageReportTarget(device['id'], device['registrationId'],
        device['subjectId'], device['displayName'],
        platform: device['platform']);
    if (!target.valid) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('设备信息已变化，请刷新。')));
      return;
    }
    setState(() => opening = true);
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            ParentDeviceReportPage(session: widget.session, target: target)));
    if (current) setState(() => opening = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('使用情况报告')),
      body: AnimatedBuilder(
          animation: devices,
          builder: (context, _) => RefreshIndicator(
              onRefresh: devices.reload,
              child: ListView(padding: const EdgeInsets.all(20), children: [
                Text('选择要了解的设备',
                    style: Theme.of(context).textTheme.headlineSmall),
                const Text(
                    '只显示已授权的使用观测。未授权、缺少数据和实际使用为零分别展示；不同应用的时长不能直接相加为总屏幕时长。'),
                if (devices.loading || devices.loadingMore)
                  const LinearProgressIndicator(),
                if (devices.error != null) ...[
                  Text('${devices.error}'),
                  TextButton(
                      onPressed: devices.reload, child: const Text('重新读取'))
                ],
                if (devices.loaded && devices.items.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(24), child: Text('还没有可查看的设备。')),
                for (final device in devices.items)
                  Card(
                      child: ListTile(
                          title: Text(device['displayName'] ?? '未命名设备'),
                          subtitle: Text(
                              '${device['platform']} · ${device['state'] == 'ACTIVE' ? '已激活，点击核对授权数据' : '当前注册不可用'}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: opening || device['state'] != 'ACTIVE'
                              ? null
                              : () => _open(device))),
                if (devices.hasMore)
                  TextButton(
                      onPressed: devices.loadingMore ? null : devices.loadMore,
                      child: const Text('加载更多设备')),
              ]))));
}

class ParentDeviceReportPage extends StatefulWidget {
  final ParentSession session;
  final UsageReportTarget target;
  final ParentUsageReportLoader? loader;
  const ParentDeviceReportPage(
      {super.key, required this.session, required this.target, this.loader});
  @override
  State<ParentDeviceReportPage> createState() => _ParentDeviceReportPageState();
}

class _ParentDeviceReportPageState extends State<ParentDeviceReportPage>
    with WidgetsBindingObserver {
  late final String tenant, actor, role;
  late final ParentUsageReportLoader loader;
  bool foreground = true;
  bool managingObservation = false;
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
    tenant = widget.session.tenant!['id'];
    actor = widget.session.profile!['subject'];
    role = widget.session.role;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    loader = widget.loader ??
        ParentUsageReportLoader(
            api: widget.session.api,
            tenant: tenant,
            token: widget.session.token,
            available: () => current && foreground);
    widget.session.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }

  void _changed() {
    if (!mounted || current) return;
    loader.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) loader.cancel();
  }

  @override
  void dispose() {
    loader.cancel();
    widget.session.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(widget.target.displayName), actions: [
        IconButton(
            tooltip: '管理观察授权',
            icon: const Icon(Icons.privacy_tip_outlined),
            onPressed: managingObservation || !current
                ? null
                : () async {
                    loader.cancel();
                    setState(() => managingObservation = true);
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ParentObservationPage(
                            session: widget.session, target: widget.target)));
                    if (current) setState(() => managingObservation = false);
                  }),
      ]),
      body: managingObservation
          ? const SizedBox.shrink()
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: DeviceUsageReportView(
                  title: '设备使用情况',
                  notAuthorizedMessage:
                      '当前没有有效的使用观察授权。请通过右上角“管理观察授权”核对范围；这里不会展示以前的用量。',
                  description: '查看授权的应用使用区间、趋势与配置证据。缺少观测不会当作零使用。',
                  load: (window) => loader.load(UsageReportQuery(
                      targets: [widget.target],
                      from: window.from,
                      to: window.to,
                      timeZone: window.timeZone,
                      period: window.period)),
                  cancel: loader.cancel,
                  accessChanges: widget.session,
                  available: () => current && foreground,
                  timeZone: widget.session.tenant?['timeZone'] as String? ??
                      'Asia/Shanghai')));
}
