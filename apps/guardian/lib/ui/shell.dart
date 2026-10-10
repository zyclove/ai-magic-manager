import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/session.dart';
import '../core/notifications.dart';
import '../core/labels.dart';
import '../pages/console_pages.dart';
import 'design.dart';
import 'notification_shortcut.dart';

const destinations = [
  ('overview', '工作台', Icons.space_dashboard_outlined),
  ('subjects', '儿童档案', Icons.person_outline),
  ('classes', '班级与名册', Icons.school_outlined),
  ('devices', '设备管理', Icons.devices_outlined),
  ('applications', '应用目录', Icons.apps_outlined),
  ('schedules', '时间计划', Icons.schedule_outlined),
  ('quota', '共享额度', Icons.timelapse_outlined),
  ('policies', '策略中心', Icons.shield_outlined),
  ('approvals', '访问审批', Icons.task_alt_outlined),
  ('notifications', '通知中心', Icons.notifications_none_outlined),
  ('reports', '使用报表', Icons.bar_chart_outlined),
  ('members', '成员与邀请', Icons.group_outlined),
  ('ownership', '所有者交接', Icons.swap_horiz_outlined),
  ('audit', '审计日志', Icons.receipt_long_outlined),
  ('exports', '导出任务', Icons.file_download_outlined),
  ('support', '支持协作', Icons.support_agent_outlined),
  ('settings', '设置', Icons.settings_outlined),
];

class ConsoleShell extends StatelessWidget {
  final String section;
  const ConsoleShell({super.key, required this.section});
  NotificationRepository notificationRepository(Session session) {
    final root = session.root, role = session.role;
    return NotificationRepository(
        api: session.api,
        root: root,
        current: () =>
            session.authenticated &&
            session.tenant != null &&
            session.root == root &&
            session.role == role &&
            notificationRoles.contains(role));
  }

  Widget navigation(BuildContext context, Session s, bool drawer) => Container(
      width: 232,
      color: Colors.white,
      child: Column(children: [
        const Padding(
            padding: EdgeInsets.fromLTRB(24, 26, 20, 28),
            child: Row(children: [
              Icon(Icons.shield, color: navy, size: 34),
              SizedBox(width: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('智能管家',
                    style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                        color: navy)),
                Text('AI MANAGER',
                    style:
                        TextStyle(fontSize: 10, letterSpacing: 2, color: muted))
              ])
            ])),
        Expanded(
            child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
              for (final d in destinations.where((d) => s.canOpen(d.$1)))
                Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                        minLeadingWidth: 22,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        selected: section == d.$1,
                        selectedTileColor: const Color(0xFFEAF2FC),
                        selectedColor: navy,
                        leading: Icon(d.$3, size: 21),
                        title: Text(d.$2,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: section == d.$1
                                    ? FontWeight.w600
                                    : FontWeight.w400)),
                        onTap: () {
                          if (drawer) Navigator.pop(context);
                          context.go(d.$1 == 'overview' ? '/' : '/${d.$1}');
                        }))
            ])),
        const Divider(),
        Padding(
            padding: const EdgeInsets.all(18),
            child: Row(children: [
              const CircleAvatar(
                  radius: 18,
                  backgroundColor: canvas,
                  child: Icon(Icons.person_outline, size: 20, color: muted)),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(s.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12)),
                    Text(label(s.role),
                        style: const TextStyle(fontSize: 11, color: muted))
                  ])),
              IconButton(
                  tooltip: '退出登录',
                  onPressed: s.logout,
                  icon: const Icon(Icons.logout, size: 18))
            ]))
      ]));
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    return Scaffold(
        drawer: wide ? null : Drawer(child: navigation(context, s, true)),
        body: SafeArea(
            child: Row(children: [
          if (wide) navigation(context, s, false),
          if (wide) const VerticalDivider(width: 1),
          Expanded(
              child: Column(children: [
            Container(
                height: 68,
                color: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(children: [
                  if (!wide)
                    Builder(
                        builder: (ctx) => IconButton(
                            tooltip: '打开导航',
                            onPressed: () => Scaffold.of(ctx).openDrawer(),
                            icon: const Icon(Icons.menu))),
                  if (wide)
                    Expanded(
                        child: Text(
                            destinations
                                    .where((d) => d.$1 == section)
                                    .firstOrNull
                                    ?.$2 ??
                                '工作台',
                            style:
                                const TextStyle(color: muted, fontSize: 13))),
                  if (!wide) const SizedBox(width: 8),
                  if (s.tenant != null)
                    ConstrainedBox(
                        constraints: BoxConstraints(
                            maxWidth: wide
                                ? 280
                                : (MediaQuery.sizeOf(context).width - 204)
                                    .clamp(100, 280)
                                    .toDouble()),
                        child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                                value: s.tenant!['id'],
                                isExpanded: true,
                                icon: const Icon(Icons.expand_more, size: 19),
                                items: s.tenants
                                    .map((t) => DropdownMenuItem<String>(
                                        value: t['id'],
                                        child: Text(t['name'],
                                            overflow: TextOverflow.ellipsis,
                                            style:
                                                const TextStyle(fontSize: 13))))
                                    .toList(),
                                onChanged: (id) async {
                                  if (id == null) return;
                                  try {
                                    await s.selectTenant(s.tenants
                                        .firstWhere((t) => t['id'] == id));
                                    if (context.mounted) context.go('/');
                                  } catch (e) {
                                    if (context.mounted) {
                                      toast(context, e.toString());
                                    }
                                  }
                                }))),
                  if (!wide) const Spacer(),
                  if (s.tenant != null && s.canOpen('notifications'))
                    NotificationShortcut(
                        key: ValueKey('notifications-${s.root}-${s.role}'),
                        repository: notificationRepository(s),
                        onOpen: () => context.go('/notifications')),
                  const SizedBox(width: 12),
                  PopupMenuButton<String>(
                      tooltip: '账户',
                      icon: const CircleAvatar(
                          radius: 17,
                          backgroundColor: canvas,
                          child: Icon(Icons.person_outline,
                              size: 20, color: navy)),
                      onSelected: (v) {
                        if (v == 'logout') {
                          s.logout();
                        } else if (v == 'account') {
                          s.account();
                        } else {
                          s.login(stepUp: true);
                        }
                      },
                      itemBuilder: (_) => const [
                            PopupMenuItem(
                                value: 'account', child: Text('账户与多因素认证')),
                            PopupMenuItem(
                                value: 'verify', child: Text('重新安全验证')),
                            PopupMenuDivider(),
                            PopupMenuItem(value: 'logout', child: Text('退出登录'))
                          ])
                ])),
            const Divider(),
            Expanded(
                child: SingleChildScrollView(
                    key: ValueKey('${s.tenant?['id']}-$section'),
                    padding: EdgeInsets.all(wide ? 32 : 18),
                    child: ConsolePages(
                        section: section,
                        key: ValueKey('${s.tenant?['id']}-$section'))))
          ]))
        ])));
  }
}
