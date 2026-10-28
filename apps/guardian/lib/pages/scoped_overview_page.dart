import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/overview_summary.dart';
import '../core/overview_attention.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/workbench_task_card.dart';
import 'device_subflow_scope.dart';

/// Read-only workbench for roles without family/organization administration rights.
class ScopedOverviewPage extends StatefulWidget {
  final Session session;
  const ScopedOverviewPage({super.key, required this.session});

  @override
  State<ScopedOverviewPage> createState() => _ScopedOverviewPageState();
}

class _ScopedOverviewPageState extends State<ScopedOverviewPage> {
  OverviewSummary? summary;
  DateTime? refreshedAt;
  Object? error;
  int generation = 0;
  DeviceSubflowScope? _scope;
  bool reading = false, _active = true, _serverDenied = false;
  bool _rebuildPending = false;

  @override
  void initState() {
    super.initState();
    _bindScope();
  }

  bool _sameContext(DeviceSubflowScope? scope) {
    if (scope == null || !mounted || !_active || !identical(_scope, scope)) {
      return false;
    }
    final session = scope.session;
    return identical(widget.session, session) &&
        session.authenticated &&
        session.tenant != null &&
        !session.canWrite &&
        session.canOpen('overview') &&
        session.scopeGeneration == scope.generation &&
        session.profile?['subject'] == scope.actorId &&
        session.tenant?['id'] == scope.tenantId &&
        session.role == scope.role;
  }

  bool _current(DeviceSubflowScope? scope) =>
      _sameContext(scope) && scope!.current;

  void _requestBuild() {
    if (!mounted || !_active || _rebuildPending) return;
    _rebuildPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildPending = false;
      if (mounted && _active) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _clear() {
    generation++;
    summary = null;
    refreshedAt = null;
    error = null;
    reading = false;
  }

  void _scopeChanged() {
    if (_current(_scope)) return;
    _clear();
    _requestBuild();
  }

  void _releaseScope() {
    final previous = _scope;
    _scope = null;
    previous?.removeListener(_scopeChanged);
    previous?.dispose();
  }

  void _bindScope() {
    _releaseScope();
    _clear();
    _serverDenied = false;
    final session = widget.session;
    if (!_active ||
        !session.authenticated ||
        session.tenant == null ||
        session.canWrite ||
        !session.canOpen('overview')) return;
    final scope = DeviceSubflowScope(session,
        permitted: () =>
            mounted &&
            _active &&
            !_serverDenied &&
            identical(widget.session, session) &&
            !session.canWrite &&
            session.canOpen('overview'));
    _scope = scope;
    scope.addListener(_scopeChanged);
    _load(scope);
  }

  @override
  void didUpdateWidget(ScopedOverviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameContext(_scope)) _bindScope();
  }

  Future<void> _load(DeviceSubflowScope? scope) async {
    if (!_current(scope) || reading) return;
    final epoch = ++generation;
    final root = scope!.session.root;
    setState(() {
      reading = true;
      error = null;
    });
    try {
      final next =
          OverviewSummary.parse(await scope.api.send('GET', '$root/overview'));
      if (epoch == generation && _current(scope)) {
        setState(() {
          summary = next;
          refreshedAt = DateTime.now();
        });
      }
    } catch (failure) {
      if (epoch == generation && _current(scope)) {
        setState(() {
          error = failure;
          if (failure is ApiFailure &&
              failure.code != 'REAUTH_REQUIRED' &&
              (failure.status == 401 ||
                  failure.status == 403 ||
                  failure.code == 'WORKSPACE_CHANGED')) {
            summary = null;
            refreshedAt = null;
            reading = false;
            _serverDenied = true;
            // Permanently revoke this capture even if Session has not yet
            // received the server's authorization change.
            scope.dispose();
          }
        });
      }
    } finally {
      if (epoch == generation && _current(scope)) {
        setState(() => reading = false);
      }
    }
  }

  @override
  void deactivate() {
    _active = false;
    _releaseScope();
    _clear();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    _bindScope();
  }

  @override
  void dispose() {
    _active = false;
    _clear();
    _releaseScope();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = _scope;
    if (!_current(scope)) {
      return Panel(
          child: Column(children: [
        const EmptyView('工作空间或权限已变化', '已隐藏旧数据，请重新打开当前工作空间的工作台。'),
        if (_serverDenied && error != null && _sameContext(scope))
          FailureView(error!, reauth: () {
            if (_serverDenied && _sameContext(scope)) {
              scope!.session.login(stepUp: true);
            }
          }),
      ]));
    }
    final session = widget.session;
    final role = session.role;
    final description = switch (role) {
      'CHILD' => '查看自己的档案、设备状态和临时访问申请；规则由监护人管理。',
      'TEACHER' => '查看获授权班级和学生的必要状态、授权学生求助，以及本人提交的访问申请。',
      'AUDITOR' => '查看策略草稿、待处理申请和最近的审计事实。',
      _ => '仅展示当前身份获准查看的信息。',
    };
    final attention = summary == null || error != null || reading
        ? null
        : OverviewAttention.pick(summary!, role: role,
            organization: session.tenant!['kind'] == 'ORGANIZATION',
            canOpen: session.canOpen);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PageHeading('欢迎，${session.displayName}',
          '${label(role)} · ${session.tenant!['name']}',
          action: TextButton.icon(
              onPressed: reading ? null : () => _load(scope),
              icon: reading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 18),
              label: Text(reading ? '正在刷新…' : '刷新状态'))),
      Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Notice(description)),
      if (error != null)
        Panel(
            child: FailureView(error!,
                retry: reading ? null : () => _load(scope),
                reauth: reading
                    ? null
                    : () {
                        if (_current(scope)) session.login(stepUp: true);
                      })),
      if (summary == null && error == null)
        const Panel(
            child: SizedBox(
                height: 180,
                child:
                    Center(child: CircularProgressIndicator(strokeWidth: 2))))
      else if (summary != null) ...[
        if (error != null || reading) ...[
          const SizedBox(height: 16),
          Notice('以下为上次成功读取的数据，当前状态尚未更新。', warning: error != null),
          const SizedBox(height: 16),
        ],
        if (attention != null) ...[
          WorkbenchTaskCard.attention(attention,
              buttonKey: const Key('scoped-overview-next-action'),
              onPressed: () => _open(scope, attention.section, location: attention.location)),
          const SizedBox(height: 20),
        ],
        LayoutBuilder(
            builder: (context, box) =>
                Wrap(spacing: 16, runSpacing: 16, children: [
                  if (role != 'AUDITOR' && summary!.subjectCount != null)
                    _metric(box.maxWidth, '可见档案', summary!.subjectCount!,
                        Icons.person_outline),
                  if (role != 'AUDITOR' && summary!.activeDeviceCount != null)
                    _metric(box.maxWidth, '已注册设备', summary!.activeDeviceCount!,
                        Icons.devices_outlined),
                  if (role == 'AUDITOR' && summary!.policyDraftCount != null)
                    _metric(box.maxWidth, '策略草稿', summary!.policyDraftCount!,
                        Icons.description_outlined),
                  _metric(box.maxWidth, role == 'AUDITOR' ? '待处理申请' : '我的待处理申请',
                      summary!.pendingRequestCount, Icons.schedule_outlined),
                  if (role == 'TEACHER' &&
                      summary!.openHelpRequestCount != null)
                    _metric(
                        box.maxWidth,
                        '授权学生待查看求助',
                        summary!.openHelpRequestCount!,
                        Icons.volunteer_activism_outlined),
                ])),
        if (role != 'AUDITOR' && (summary!.connectionCheckCount ?? 0) > 0 &&
            attention?.kind != OverviewAttentionKind.connection) ...[
          const SizedBox(height: 16),
          Notice(
              '${summary!.connectionCheckCount} 台可见设备尚无近期心跳。请检查连接；失联不能证明规则已失效。',
              warning: true),
        ],
        if (role == 'TEACHER' && (summary!.openHelpRequestCount ?? 0) > 0 &&
            attention?.kind != OverviewAttentionKind.help) ...[
          const SizedBox(height: 16),
          Notice(
              '当前授权范围有 ${summary!.openHelpRequestCount} 条学生求助尚未确认看到。请打开收件记录，并按机构流程实际联系与跟进。',
              warning: true),
        ],
      ],
      const SizedBox(height: 20),
      Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('可用入口', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 16),
        Wrap(spacing: 10, runSpacing: 10, children: [
          if (session.canOpen('classes'))
            _link('我的班级', Icons.school_outlined, '/classes'),
          if (session.canOpen('subjects'))
            _link('我的档案', Icons.person_outline, '/subjects'),
          if (session.canOpen('devices'))
            _link('我的设备', Icons.devices_outlined, '/devices'),
          if (session.canOpen('approvals'))
            _link('访问申请', Icons.task_alt_outlined, '/approvals'),
          if (session.canOpen('help-requests'))
            _link(
                '授权学生求助', Icons.volunteer_activism_outlined, '/help-requests'),
          if (session.canOpen('policies'))
            _link('策略中心', Icons.shield_outlined, '/policies'),
          if (session.canOpen('audit'))
            _link('审计日志', Icons.receipt_long_outlined, '/audit'),
        ])
      ])),
      if (summary != null &&
          role == 'AUDITOR' &&
          summary!.recentActivity.isNotEmpty) ...[
        const SizedBox(height: 20),
        Panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('最近审计事实', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final activity in summary!.recentActivity)
            ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.receipt_long_outlined),
                title: Text(label(activity.action)),
                subtitle: Text(shortId(activity.resourceId)),
                trailing: Text(dateLabel(activity.occurredAt))),
        ]))
      ],
      if (summary != null && refreshedAt != null)
        Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text('上次读取完成：${dateLabel(refreshedAt!.toIso8601String())}',
                style: const TextStyle(color: muted, fontSize: 12))),
    ]);
  }

  Widget _metric(double width, String title, int value, IconData icon) {
    final minimum = MediaQuery.textScalerOf(context).scale(1) > 1.2 ? 240 : 170;
    final columns = (width / minimum).floor().clamp(1, 3);
    return SizedBox(
        width: (width - (columns - 1) * 16) / columns,
        child: Panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 25, color: muted),
          const SizedBox(height: 12),
          Text('$value',
              style: const TextStyle(
                  fontSize: 28, fontWeight: FontWeight.w700, color: ink)),
          const SizedBox(height: 4),
          Text(title, style: const TextStyle(color: muted, fontSize: 13))
        ])));
  }

  void _open(DeviceSubflowScope? scope, String section, {String? location}) {
    if (_current(scope) && scope!.session.canOpen(section)) {
      context.go(location ?? '/$section');
    }
  }

  Widget _link(String text, IconData icon, String route) {
    final scope = _scope;
    final section = route.substring(1);
    return OutlinedButton.icon(
        onPressed: () => _open(scope, section),
        icon: Icon(icon, size: 18),
        label: Text(text));
  }
}
