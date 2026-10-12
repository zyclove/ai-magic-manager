import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/labels.dart';
import '../core/overview_summary.dart';
import '../core/session.dart';
import '../ui/design.dart';

/// Read-only workbench for roles without family/organization administration rights.
class ScopedOverviewPage extends StatefulWidget {
  final Session session;
  const ScopedOverviewPage({super.key, required this.session});

  @override
  State<ScopedOverviewPage> createState() => _ScopedOverviewPageState();
}

class _ScopedOverviewPageState extends State<ScopedOverviewPage> {
  OverviewSummary? summary;
  Object? error;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final epoch = ++generation;
    final session = widget.session;
    final root = session.root, role = session.role;
    setState(() {
      summary = null;
      error = null;
    });
    try {
      final next = OverviewSummary.parse(
          await session.api.send('GET', '$root/overview'));
      if (mounted &&
          epoch == generation &&
          session.tenant != null &&
          session.root == root &&
          session.role == role) {
        setState(() => summary = next);
      }
    } catch (failure) {
      if (mounted &&
          epoch == generation &&
          session.tenant != null &&
          session.root == root &&
          session.role == role) {
        setState(() => error = failure);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final role = session.role;
    final description = switch (role) {
      'CHILD' => '查看自己的档案、设备状态和临时访问申请；规则由监护人管理。',
      'TEACHER' => '查看获授权班级和学生的必要状态、授权学生求助，以及本人提交的访问申请。',
      'AUDITOR' => '查看策略草稿、待处理申请和最近的审计事实。',
      _ => '仅展示当前身份获准查看的信息。',
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PageHeading('欢迎，${session.displayName}',
          '${label(role)} · ${session.tenant!['name']}'),
      Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Notice(description)),
      if (error != null)
        Panel(
            child: FailureView(error!,
                retry: load, reauth: () => session.login(stepUp: true)))
      else if (summary == null)
        const Panel(
            child: SizedBox(
                height: 180,
                child:
                    Center(child: CircularProgressIndicator(strokeWidth: 2))))
      else ...[
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
        if (role != 'AUDITOR' && (summary!.connectionCheckCount ?? 0) > 0) ...[
          const SizedBox(height: 16),
          Notice(
              '${summary!.connectionCheckCount} 台可见设备尚无近期心跳。请检查连接；失联不能证明规则已失效。',
              warning: true),
        ],
        if (role == 'TEACHER' && (summary!.openHelpRequestCount ?? 0) > 0) ...[
          const SizedBox(height: 16),
          Notice(
              '当前授权范围有 ${summary!.openHelpRequestCount} 条学生求助尚未确认看到。请打开收件记录，并按机构流程实际联系与跟进。',
              warning: true),
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
              _link('授权学生求助', Icons.volunteer_activism_outlined,
                  '/help-requests'),
            if (session.canOpen('policies'))
              _link('策略中心', Icons.shield_outlined, '/policies'),
            if (session.canOpen('audit'))
              _link('审计日志', Icons.receipt_long_outlined, '/audit'),
          ])
        ])),
        if (role == 'AUDITOR' && summary!.recentActivity.isNotEmpty) ...[
          const SizedBox(height: 20),
          Panel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
        const SizedBox(height: 16),
        Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
                onPressed: load,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新状态')))
      ]
    ]);
  }

  Widget _metric(double width, String title, int value, IconData icon) =>
      SizedBox(
          width: width < 560 ? (width - 16) / 2 : 194,
          child: Panel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Icon(icon, size: 25, color: muted),
                const SizedBox(height: 12),
                Text('$value',
                    style: const TextStyle(
                        fontSize: 28, fontWeight: FontWeight.w700, color: ink)),
                const SizedBox(height: 4),
                Text(title, style: const TextStyle(color: muted, fontSize: 13))
              ])));

  Widget _link(String text, IconData icon, String route) => OutlinedButton.icon(
      onPressed: () => context.go(route),
      icon: Icon(icon, size: 18),
      label: Text(text));
}
