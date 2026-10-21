import 'dart:async';
import 'package:flutter/material.dart';
import '../core/family.dart';
import '../core/family_requests.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import 'device_capabilities.dart';
import 'family_device_access_page.dart';
import 'family_membership.dart';
import 'family_requests_page.dart';
import 'family_workspace.dart';
import 'help_center.dart';

/// The home already loads its dashboard. This entry adds no polling or count
/// from a different inbox; opening it reads the current family's actual facts.
class FamilyInboxShortcut extends StatelessWidget {
  final ParentSession session;
  const FamilyInboxShortcut({super.key, required this.session});
  @override
  Widget build(BuildContext context) => IconButton(
      tooltip: '消息与待办',
      icon: const Icon(Icons.notifications_none_outlined),
      onPressed: session.authenticated &&
              session.tenant?['kind'] == 'FAMILY' &&
              const {'OWNER', 'GUARDIAN'}.contains(session.role)
          ? () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => FamilyInboxPage(session: session)))
          : null);
}

/// Push IDs are deliberately absent: they select neither a child nor an actor.
/// Every action starts with current authorized family dashboard and inbox data.
class FamilyInboxPage extends StatefulWidget {
  final ParentSession session;
  final FamilyDecisionJournal? decisionJournal;
  const FamilyInboxPage(
      {super.key, required this.session, this.decisionJournal});
  @override
  State<FamilyInboxPage> createState() => _FamilyInboxPageState();
}

class _FamilyInboxPageState extends State<FamilyInboxPage>
    with FamilyScope<FamilyInboxPage>, WidgetsBindingObserver {
  @override
  ParentSession get session => widget.session;
  FamilyDashboard? snapshot;
  Object? error;
  bool busy = false, foreground = true;
  int epoch = 0;
  Future<void>? reading;
  bool get active => current && foreground;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (foreground) unawaited(refresh());
  }

  Future<void> refresh() {
    if (!active || busy) return Future<void>.value();
    final requestEpoch = epoch;
    setState(() {
      busy = true;
      error = null;
      snapshot = null;
    });
    final operation = () async {
      try {
        final scoped = FamilyService(
            api: session.api,
            tenantId: scopeTenant,
            available: () => active && epoch == requestEpoch);
        final result = await scoped.dashboard();
        if (active && epoch == requestEpoch) setState(() => snapshot = result);
      } catch (failure) {
        if (active && epoch == requestEpoch) setState(() => error = failure);
      } finally {
        if (mounted) setState(() => busy = false);
      }
    }();
    reading = operation;
    return operation;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state != AppLifecycleState.resumed && foreground) {
      setState(() {
        foreground = false;
        epoch++;
        snapshot = null;
        error = null;
      });
    } else if (state == AppLifecycleState.resumed && !foreground) {
      setState(() => foreground = true);
      unawaited(resume());
    }
  }

  Future<void> resume() async {
    final value = epoch;
    await reading;
    if (active && epoch == value) await refresh();
  }

  Future<void> open(Widget page, {String? title}) async {
    if (!active) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => title == null
            ? page
            : Scaffold(appBar: AppBar(title: Text(title)), body: page)));
    if (active) await refresh();
  }

  Future<void> inspectDevice(FamilyDevice device) async {
    if (!active) return;
    await showDeviceCapabilities(context, session, device.id);
    if (active) await refresh();
  }

  @override
  void dispose() {
    epoch++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String deviceStatus(FamilyDevice device) {
    if (device.runtime == null) return '运行状态待核对';
    return switch (device.ruleState) {
      'ACTIVE' => '设备报告辅助限制已启用',
      'DISABLED' => '当前未启用辅助限制',
      'STALE' => '最近状态未更新，请检查设备连接',
      'PERMISSION_MISSING' => '需要在儿童设备补充授权',
      'CONSENT_REQUIRED' => '需要在儿童设备确认辅助限制授权',
      'CONFIGURATION_INVALID' ||
      'EXPIRED' ||
      'CONFIGURATION_UNAVAILABLE' =>
        '设备上的规则需要重新核对',
      'CLOCK_ANOMALY' => '设备时间发生变化，请检查时间设置',
      'STORAGE_FAILURE' => '设备保存运行记录失败，请检查并恢复',
      _ => '运行状态待核对'
    };
  }

  @override
  Widget build(BuildContext context) {
    final data = snapshot;
    return Scaffold(
        appBar: AppBar(title: const Text('消息与待办'), actions: [
          IconButton(
              tooltip: '刷新家庭待办',
              onPressed: active && !busy ? refresh : null,
              icon: const Icon(Icons.refresh))
        ]),
        body: !current
            ? const Center(child: Text('当前家庭或权限已变化，请返回重新打开。'))
            : !foreground
                ? const Center(child: Text('家庭内容已隐藏，返回后会重新读取。'))
                : RefreshIndicator(
                    onRefresh: refresh,
                    child: ListView(
                        padding: const EdgeInsets.all(20),
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          if (busy) const LinearProgressIndicator(),
                          if (error != null)
                            FamilyNotice(
                                error is ParentApiException
                                    ? familyError(error!)
                                    : '暂时无法读取家庭待办，请检查网络后重试。',
                                error: true),
                          if (error != null)
                            OutlinedButton(
                                onPressed: busy ? null : refresh,
                                child: const Text('重新读取')),
                          if (data != null) ...[
                            FamilyPanel(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  const Icon(Icons.favorite_outline,
                                      size: 32, color: familyInk),
                                  const SizedBox(height: 12),
                                  Text(
                                      data.pendingRequestCount > 0
                                          ? '孩子在等你的答复'
                                          : '看看家里的最新状态',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge),
                                  const SizedBox(height: 8),
                                  const Text('先处理申请和求助，再核对设备与会员状态。',
                                      style: TextStyle(color: familyMuted)),
                                  const SizedBox(height: 12),
                                  ListTile(
                                      key: const ValueKey(
                                          'family-inbox-requests'),
                                      contentPadding: EdgeInsets.zero,
                                      leading:
                                          const Icon(Icons.fact_check_outlined),
                                      title: const Text('孩子的申请'),
                                      subtitle: Text(data.pendingRequestCount ==
                                              0
                                          ? '当前没有待处理申请'
                                          : '${data.pendingRequestCount} 项待处理'),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: () => open(
                                          FamilyRequestsPage(
                                              session: session,
                                              journal: widget.decisionJournal),
                                          title: '孩子的申请')),
                                  ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      leading:
                                          const Icon(Icons.favorite_border),
                                      title: const Text('孩子的求助'),
                                      subtitle: Text(data
                                                  .openHelpRequestCount ==
                                              0
                                          ? '当前没有待查看求助'
                                          : '${data.openHelpRequestCount} 条待查看'),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: () => open(
                                          ParentHelpCenter(session: session),
                                          title: '孩子的求助')),
                                ])),
                            if (data.children.isEmpty)
                              const FamilyNotice('还没有孩子和设备，连接后可在这里查看申请与运行状态。'),
                            if (data.deviceAccess != null)
                              FamilyDeviceAccessSummary(
                                  snapshot: data.deviceAccess!,
                                  onOpen: () => open(FamilyDeviceAccessPage(
                                      session: session))),
                            FamilyMembershipEntry(session: session),
                            FamilyPanel(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                  Text('设备状态',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge),
                                  const SizedBox(height: 8),
                                  if (data.children
                                      .every((child) => child.devices.isEmpty))
                                    const Text('还没有连接的儿童设备。'),
                                  for (final child in data.children)
                                    for (final device in child.devices) ...[
                                      const SizedBox(height: 12),
                                      Text(
                                          '${child.nickname} · ${device.displayName}',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700)),
                                      const SizedBox(height: 4),
                                      Text(deviceStatus(device)),
                                      if (device.lastHeartbeatAt == null)
                                        const Text('尚未收到设备联系',
                                            style:
                                                TextStyle(color: familyMuted)),
                                      TextButton.icon(
                                          onPressed: () =>
                                              inspectDevice(device),
                                          icon: const Icon(
                                              Icons.verified_user_outlined),
                                          label: const Text('检查设备状态')),
                                    ],
                                  const SizedBox(height: 8),
                                  const Text('运行状态由儿童设备最近上报，实际效果仍需在设备上核对。',
                                      style: TextStyle(color: familyMuted)),
                                ])),
                          ] else if (!busy && error == null)
                            const FamilyNotice('请重新读取当前家庭的待办。'),
                        ])));
  }
}
