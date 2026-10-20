import 'package:flutter/material.dart';
import '../core/labels.dart';
import '../core/overview_summary.dart';
import 'design.dart';

/// Presentation only: counts and availability come from the current workspace.
/// The host owns authentication, requests, mutations and refresh completion.
class WorkbenchView extends StatelessWidget {
  final String workspaceName, role;
  final bool organization, busy, refreshing;
  final OverviewSummary? summary;
  final Object? error;
  final DateTime? refreshedAt;
  final bool Function(String section) canOpen;
  final ValueChanged<String> onOpen;
  final VoidCallback? onAddSubject, onAddDevice;
  final VoidCallback onRefresh, onReauth;

  const WorkbenchView({
    super.key,
    required this.workspaceName,
    required this.role,
    required this.organization,
    required this.summary,
    required this.canOpen,
    required this.onOpen,
    required this.onRefresh,
    required this.onReauth,
    this.onAddSubject,
    this.onAddDevice,
    this.error,
    this.refreshedAt,
    this.busy = false,
    this.refreshing = false,
  });

  String get subjectWord => organization ? '学生' : '儿童';

  void _open(String section) {
    if (canOpen(section)) onOpen(section);
  }

  _WorkbenchAction? _nextAction(OverviewSummary value) {
    if ((value.openHelpRequestCount ?? 0) > 0 && canOpen('help-requests')) {
      return _WorkbenchAction(
          '先查看$subjectWord求助',
          '有 ${value.openHelpRequestCount} 条求助尚未确认看到。请核对内容，并实际联系与跟进。',
          '查看求助',
          Icons.volunteer_activism_outlined,
          () => onOpen('help-requests'),
          section: 'help-requests',
          urgent: true);
    }
    if (value.pendingRequestCount > 0 && canOpen('approvals')) {
      return _WorkbenchAction(
          '处理待审批的访问申请',
          '有 ${value.pendingRequestCount} 条申请等待处理。先查看申请理由，再决定是否允许临时访问。',
          '查看待处理审批',
          Icons.task_alt_outlined,
          () => onOpen('approvals'),
          section: 'approvals');
    }
    if ((value.connectionCheckCount ?? 0) > 0 && canOpen('devices')) {
      return _WorkbenchAction(
          '检查设备连接',
          '${value.connectionCheckCount} 台设备尚无近期心跳。请检查连接；心跳缺失不能证明设备规则已失效。',
          '查看设备连接',
          Icons.wifi_off_outlined,
          () => onOpen('devices'),
          section: 'devices');
    }
    if (value.subjectCount == 0 &&
        canOpen('subjects') &&
        onAddSubject != null) {
      return _WorkbenchAction(
          '先添加一份$subjectWord档案',
          '填写昵称和年龄段即可，之后就能连接设备。无需填写完整生日。',
          '添加$subjectWord档案',
          Icons.person_add_alt_outlined,
          onAddSubject!,
          section: 'subjects',
          shortcut: 'add-subject');
    }
    if ((value.subjectCount ?? 0) > 0 &&
        value.activeDeviceCount == 0 &&
        canOpen('devices') &&
        onAddDevice != null) {
      return _WorkbenchAction(
          '为$subjectWord连接设备',
          '档案已准备好。选择所属$subjectWord，再按设备端提示完成配对。',
          '连接设备',
          Icons.add_to_home_screen_outlined,
          onAddDevice!,
          section: 'devices',
          shortcut: 'add-device');
    }
    if (value.policyDraftCount == 0 && canOpen('policies')) {
      return _WorkbenchAction('设置使用规则', '到规则中心检查已有规则或添加新规则。配置保存与设备实际执行状态分别查看。',
          '设置使用规则', Icons.shield_outlined, () => onOpen('policies'),
          section: 'policies', shortcut: 'policies');
    }
    if (canOpen('reports')) {
      return _WorkbenchAction(
          '了解最近的设备使用情况',
          '查看已授权设备的使用报表。未授权或缺失的数据会明确标记，不能当作零使用量。',
          '查看使用报表',
          Icons.bar_chart_outlined,
          () => onOpen('reports'),
          section: 'reports',
          shortcut: 'reports');
    }
    if (canOpen('devices')) {
      return _WorkbenchAction('查看当前设备', '检查已注册设备的连接、能力和实际回执。', '查看设备',
          Icons.devices_outlined, () => onOpen('devices'),
          section: 'devices');
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final value = summary;
    final action = value == null ? null : _nextAction(value);
    final commonActions =
        value == null ? null : _commonActions(context, action?.shortcut);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PageHeading('工作台',
          '$workspaceName · ${organization ? '机构管理' : '家庭管理'} · ${label(role)}',
          action: TextButton.icon(
              onPressed:
                  busy || refreshing || (value == null && error == null)
                      ? null
                      : onRefresh,
              icon: refreshing && value != null
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 18),
              label: Text(refreshing ? '正在刷新…' : '刷新状态'))),
      if (error != null)
        Panel(child: FailureView(error!, retry: onRefresh, reauth: onReauth))
      else if (value == null)
        const Panel(
            child: SizedBox(
                height: 180,
                child:
                    Center(child: CircularProgressIndicator(strokeWidth: 2))))
      else ...[
        if (action != null) ...[
          _primaryAction(context, action),
          const SizedBox(height: 20),
        ],
        _metrics(context, value),
        if (commonActions != null) ...[
          const SizedBox(height: 20),
          commonActions,
        ],
        if (canOpen('audit')) ...[
          const SizedBox(height: 20),
          _recentActivity(context, value),
        ],
        if (refreshedAt != null)
          Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text('上次读取完成：${dateLabel(refreshedAt!.toIso8601String())}',
                  style: const TextStyle(color: muted, fontSize: 12))),
      ]
    ]);
  }

  Widget _primaryAction(BuildContext context, _WorkbenchAction action) => Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(action.icon,
              size: 24, color: action.urgent ? const Color(0xFFA7473C) : navy),
          const SizedBox(width: 10),
          Expanded(
              child: Text(action.urgent ? '需要优先关注' : '接下来可以做',
                  style: TextStyle(
                      color: action.urgent ? const Color(0xFFA7473C) : muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 16),
        Text(action.title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(action.description,
            style: const TextStyle(color: muted, height: 1.7)),
        const SizedBox(height: 18),
        Semantics(
            liveRegion: busy,
            child: FilledButton.icon(
                key: const Key('workbench-next-action'),
                onPressed: busy
                    ? null
                    : () {
                        if (canOpen(action.section)) action.run();
                      },
                icon: busy
                    ? SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant))
                    : const Icon(Icons.arrow_forward, size: 18),
                label: Text(busy ? '处理中…' : action.label,
                    textAlign: TextAlign.center))),
      ]));

  Widget _metrics(BuildContext context, OverviewSummary value) {
    final entries = <({
      String key,
      String title,
      int count,
      String section,
      IconData icon,
      bool attention
    })>[
      if (value.subjectCount != null && canOpen('subjects'))
        (
          key: 'subjects',
          title: '$subjectWord档案',
          count: value.subjectCount!,
          section: 'subjects',
          icon: Icons.person_outline,
          attention: false
        ),
      if (value.activeDeviceCount != null && canOpen('devices'))
        (
          key: 'devices',
          title: '管理中设备',
          count: value.activeDeviceCount!,
          section: 'devices',
          icon: Icons.devices_outlined,
          attention: false
        ),
      if (canOpen('approvals'))
        (
          key: 'approvals',
          title: '待处理审批',
          count: value.pendingRequestCount,
          section: 'approvals',
          icon: Icons.task_alt_outlined,
          attention: value.pendingRequestCount > 0
        ),
      if (value.openHelpRequestCount != null && canOpen('help-requests'))
        (
          key: 'help',
          title: '$subjectWord求助待查看',
          count: value.openHelpRequestCount!,
          section: 'help-requests',
          icon: Icons.volunteer_activism_outlined,
          attention: value.openHelpRequestCount! > 0
        ),
      if (value.connectionCheckCount != null && canOpen('devices'))
        (
          key: 'connections',
          title: '连接待检查',
          count: value.connectionCheckCount!,
          section: 'devices',
          icon: Icons.wifi_off_outlined,
          attention: value.connectionCheckCount! > 0
        ),
      if (value.policyDraftCount != null && canOpen('policies'))
        (
          key: 'policies',
          title: '规则草稿',
          count: value.policyDraftCount!,
          section: 'policies',
          icon: Icons.shield_outlined,
          attention: false
        ),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, box) {
      final minimum =
          MediaQuery.textScalerOf(context).scale(1) > 1.2 ? 240 : 160;
      final columns = (box.maxWidth / minimum).floor().clamp(1, 3);
      final width = (box.maxWidth - (columns - 1) * 12) / columns;
      return Wrap(spacing: 12, runSpacing: 12, children: [
        for (final entry in entries)
          SizedBox(
              width: width,
              child: Material(
                  color: Colors.white,
                  shape: RoundedRectangleBorder(
                      side: const BorderSide(color: line),
                      borderRadius: BorderRadius.circular(12)),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                      key: Key('workbench-metric-${entry.key}'),
                      onTap: busy ? null : () => _open(entry.section),
                      child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Icon(entry.icon,
                                      size: 21,
                                      color: entry.attention
                                          ? const Color(0xFFA65B17)
                                          : muted),
                                  const Spacer(),
                                  const Icon(Icons.chevron_right,
                                      size: 18, color: muted),
                                ]),
                                const SizedBox(height: 14),
                                Text('${entry.count}',
                                    style: const TextStyle(
                                        fontSize: 28,
                                        fontWeight: FontWeight.w700,
                                        color: ink)),
                                const SizedBox(height: 4),
                                Text(entry.title,
                                    style: const TextStyle(color: muted)),
                              ]))))),
      ]);
    });
  }

  Widget? _commonActions(BuildContext context, String? primaryShortcut) {
    final actions = <Widget>[
      if (primaryShortcut != 'add-subject' &&
          canOpen('subjects') &&
          onAddSubject != null)
        OutlinedButton.icon(
            key: const Key('workbench-add-subject'),
            onPressed: busy
                ? null
                : () {
                    if (canOpen('subjects')) onAddSubject!();
                  },
            icon: const Icon(Icons.person_add_alt_outlined, size: 18),
            label: Text('添加$subjectWord')),
      if (primaryShortcut != 'add-device' &&
          canOpen('devices') &&
          onAddDevice != null)
        OutlinedButton.icon(
            key: const Key('workbench-add-device'),
            onPressed: busy
                ? null
                : () {
                    if (canOpen('devices')) onAddDevice!();
                  },
            icon: const Icon(Icons.add_to_home_screen_outlined, size: 18),
            label: const Text('连接设备')),
      if (primaryShortcut != 'policies' && canOpen('policies'))
        OutlinedButton.icon(
            onPressed: busy ? null : () => _open('policies'),
            icon: const Icon(Icons.shield_outlined, size: 18),
            label: const Text('设置使用规则')),
      if (primaryShortcut != 'reports' && canOpen('reports'))
        OutlinedButton.icon(
            onPressed: busy ? null : () => _open('reports'),
            icon: const Icon(Icons.bar_chart_outlined, size: 18),
            label: const Text('查看使用报表')),
    ];
    if (actions.isEmpty) return null;
    return Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('常用操作', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 16),
      Wrap(spacing: 10, runSpacing: 10, children: actions),
    ]));
  }

  Widget _recentActivity(BuildContext context, OverviewSummary value) => Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('最近活动', style: Theme.of(context).textTheme.titleMedium),
              TextButton(
                  onPressed: busy ? null : () => _open('audit'),
                  child: const Text('查看全部活动')),
            ]),
        const SizedBox(height: 8),
        if (value.recentActivity.isEmpty)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child:
                  Text('暂无活动记录，新的管理操作将在这里显示。', style: TextStyle(color: muted)))
        else
          for (final activity in value.recentActivity)
            ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.receipt_long_outlined, color: muted),
                title: Text(label(activity.action)),
                subtitle: Text(
                    '${shortId(activity.resourceId)} · ${dateLabel(activity.occurredAt)}')),
      ]));
}

class _WorkbenchAction {
  final String title, description, label;
  final String section;
  // Only the same shortcut is redundant; a section may offer other actions.
  final String? shortcut;
  final IconData icon;
  final VoidCallback run;
  final bool urgent;
  const _WorkbenchAction(
      this.title, this.description, this.label, this.icon, this.run,
      {required this.section, this.shortcut, this.urgent = false});
}
