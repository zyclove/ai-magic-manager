import 'package:flutter/material.dart';
import 'package:usage_reporting/usage_reporting.dart';
import 'package:usage_report_ui/usage_report_ui.dart';
import '../core/parent_session.dart';
import '../core/usage_reports.dart';
import 'observation_settings_page.dart';
import 'multi_device_reports.dart';

/// Parent reports expose only server-authorized activity; directory visibility is not consent.
class UsageReportCenter extends StatelessWidget {
  final ParentSession session;
  final String? subjectId;
  const UsageReportCenter({super.key, required this.session, this.subjectId});
  @override
  Widget build(BuildContext context) => ParentReportDevicePicker(
      session: session, browseFirst: true, subjectId: subjectId);
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
                  compactControls: true,
                  initialDays:
                      widget.session.tenant?['kind'] == 'FAMILY' ? 1 : 7,
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
                  timeZone: widget.session.tenant?['kind'] == 'FAMILY'
                      ? 'Asia/Shanghai'
                      : widget.session.tenant?['timeZone'] as String? ??
                          'Asia/Shanghai')));
}
