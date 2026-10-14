import 'package:flutter/material.dart';
import 'design.dart';

const destinations = [
  ('overview', '工作台', Icons.space_dashboard_outlined),
  ('subjects', '儿童档案', Icons.person_outline),
  ('classes', '班级与名册', Icons.school_outlined),
  ('device-groups', '机构设备组', Icons.grid_view_outlined),
  ('managed-android', '受管 Android', Icons.phonelink_lock_outlined),
  ('devices', '设备管理', Icons.devices_outlined),
  ('applications', '应用目录', Icons.apps_outlined),
  ('schedules', '时间计划', Icons.schedule_outlined),
  ('quota', '共享额度', Icons.timelapse_outlined),
  ('policies', '策略中心', Icons.shield_outlined),
  ('approvals', '访问审批', Icons.task_alt_outlined),
  ('notifications', '通知中心', Icons.notifications_none_outlined),
  ('help-requests', '儿童求助', Icons.volunteer_activism_outlined),
  ('reports', '使用报表', Icons.bar_chart_outlined),
  ('commercial', '商业账户', Icons.workspace_premium_outlined),
  ('catalog', '平台产品目录', Icons.inventory_2_outlined),
  ('contracts', '平台机构合同', Icons.description_outlined),
  ('managed-android-review', '企业绑定审核', Icons.fact_check_outlined),
  ('institution-contracts', '机构合同', Icons.fact_check_outlined),
  ('members', '成员与邀请', Icons.group_outlined),
  ('ownership', '所有者交接', Icons.swap_horiz_outlined),
  ('audit', '审计日志', Icons.receipt_long_outlined),
  ('exports', '导出任务', Icons.file_download_outlined),
  ('support', '支持协作', Icons.support_agent_outlined),
  ('settings', '设置', Icons.settings_outlined),
];

const navigationGroups = [
  (
    'daily',
    '日常管理',
    [
      'overview',
      'subjects',
      'devices',
      'approvals',
      'help-requests',
      'notifications'
    ]
  ),
  (
    'rules',
    '规则与报表',
    ['policies', 'schedules', 'quota', 'applications', 'reports']
  ),
  (
    'workspace',
    '工作空间',
    [
      'classes',
      'device-groups',
      'managed-android',
      'members',
      'commercial',
      'institution-contracts',
      'ownership',
      'audit',
      'exports',
      'support',
      'settings'
    ]
  ),
  ('platform', '平台管理', ['catalog', 'contracts', 'managed-android-review']),
];

String navigationLabel(String section, {bool organization = false}) {
  if (organization && section == 'subjects') return '学生档案';
  if (organization && section == 'help-requests') return '学生求助';
  return destinations.where((d) => d.$1 == section).firstOrNull?.$2 ?? '工作台';
}

/// Shared by the desktop sidebar and mobile drawer; access precedes search.
class ConsoleNavigation extends StatefulWidget {
  final String section;
  final bool Function(String) canOpen;
  final ValueChanged<String> onSelect;
  final bool organization;
  const ConsoleNavigation(
      {super.key,
      required this.section,
      required this.canOpen,
      required this.onSelect,
      this.organization = false});
  @override
  State<ConsoleNavigation> createState() => _ConsoleNavigationState();
}

class _ConsoleNavigationState extends State<ConsoleNavigation> {
  final search = TextEditingController();
  final expanded = <String, bool>{'daily': true, 'rules': true};
  String query = '';

  @override
  void initState() {
    super.initState();
    _revealCurrent();
  }

  @override
  void didUpdateWidget(ConsoleNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) _revealCurrent();
  }

  void _revealCurrent() {
    for (final group in navigationGroups) {
      if (group.$3.contains(widget.section)) expanded[group.$1] = true;
    }
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  String title((String, String, IconData) destination) =>
      navigationLabel(destination.$1, organization: widget.organization);

  @override
  Widget build(BuildContext context) {
    final available = destinations.where((d) => widget.canOpen(d.$1)).toList();
    final filtered =
        available.where((d) => title(d).toLowerCase().contains(query)).toList();
    return Column(children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: TextField(
              controller: search,
              onChanged: (value) =>
                  setState(() => query = value.trim().toLowerCase()),
              decoration: InputDecoration(
                  labelText: '查找功能',
                  hintText: '设备、报表…',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 19),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除功能搜索',
                          onPressed: () {
                            search.clear();
                            setState(() => query = '');
                          },
                          icon: const Icon(Icons.close, size: 17))))),
      Expanded(
          child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
            if (filtered.isEmpty)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24, horizontal: 8),
                  child: Text('没有匹配的可用功能，试试其他关键词。',
                      style: TextStyle(color: muted, fontSize: 13))),
            for (final group in navigationGroups)
              if (filtered.any((d) => group.$3.contains(d.$1))) ...[
                Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    child: Semantics(
                        button: true,
                        expanded:
                            query.isNotEmpty || expanded[group.$1] == true,
                        child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: query.isNotEmpty
                                ? null
                                : () => setState(() => expanded[group.$1] =
                                    !(expanded[group.$1] ?? false)),
                            child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 12),
                                child: Row(children: [
                                  Expanded(
                                      child: Text(group.$2,
                                          style: const TextStyle(
                                              color: muted,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600))),
                                  Icon(
                                      query.isNotEmpty ||
                                              expanded[group.$1] == true
                                          ? Icons.expand_less
                                          : Icons.expand_more,
                                      size: 18,
                                      color: muted)
                                ]))))),
                if (query.isNotEmpty || expanded[group.$1] == true)
                  for (final id in group.$3)
                    for (final d in filtered.where((d) => d.$1 == id))
                      Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: ListTile(
                              minLeadingWidth: 22,
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                              selected: widget.section == id,
                              selectedTileColor: const Color(0xFFEAF2FC),
                              selectedColor: navy,
                              leading: Icon(d.$3, size: 21),
                              title: Text(title(d),
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: widget.section == id
                                          ? FontWeight.w600
                                          : FontWeight.w400)),
                              onTap: () => widget.onSelect(id))),
              ],
          ])),
    ]);
  }
}
