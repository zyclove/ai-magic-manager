import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/session.dart';
import '../core/notifications.dart';
import '../core/labels.dart';
import '../pages/console_pages.dart';
import 'design.dart';
import 'notification_shortcut.dart';
import 'help_shortcut.dart';
import 'console_navigation.dart';

class ConsoleShell extends StatelessWidget {
  final String section;
  const ConsoleShell({super.key, required this.section});
  NotificationRepository notificationRepository(Session session) {
    final root = session.root, role = session.role;
    final actor = session.profile?['subject'], tenant = session.tenant?['id'];
    final generation = session.scopeGeneration;
    bool current() =>
        session.authenticated &&
        session.tenant != null &&
        session.profile?['subject'] == actor &&
        session.tenant?['id'] == tenant &&
        session.root == root &&
        session.role == role &&
        session.scopeGeneration == generation &&
        notificationRoles.contains(role);
    return NotificationRepository(
        api: session.api.scoped(current), root: root, current: current);
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
            child: ConsoleNavigation(
                key: ValueKey('navigation-${s.tenant?['id']}-${s.role}'),
                section: section,
                organization: s.tenant?['kind'] == 'ORGANIZATION',
                canOpen: s.canOpen,
                onSelect: (destination) {
                  if (drawer) Navigator.pop(context);
                  context.go(destination == 'overview' ? '/' : '/$destination');
                })),
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
    final notifications = s.tenant != null && s.canOpen('notifications')
        ? notificationRepository(s)
        : null;
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final workspacePicker = s.tenant == null
        ? null
        : ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                    value: s.tenant!['id'],
                    isExpanded: true,
                    icon: const Icon(Icons.expand_more, size: 19),
                    items: s.tenants
                        .map((t) => DropdownMenuItem<String>(
                            value: t['id'],
                            child: Text(t['name'],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13))))
                        .toList(),
                    onChanged: (id) async {
                      if (id == null || id == s.tenant?['id']) return;
                      final parentRoute = ModalRoute.of(context);
                      final actor = s.profile?['subject'];
                      var generation = s.scopeGeneration;
                      bool currentSelection() =>
                          context.mounted &&
                          parentRoute?.isCurrent == true &&
                          identical(context.read<Session>(), s) &&
                          s.authenticated &&
                          s.profile?['subject'] == actor &&
                          s.scopeGeneration == generation;
                      try {
                        final selection = s.selectTenant(
                            s.tenants.firstWhere((t) => t['id'] == id));
                        // selectTenant invalidates old scopes synchronously.
                        generation = s.scopeGeneration;
                        await selection;
                        if (context.mounted &&
                            currentSelection() && s.tenant?['id'] == id) {
                          context.go('/');
                        }
                      } catch (e) {
                        if (context.mounted && currentSelection()) {
                          toast(context, e.toString());
                        }
                      }
                    })));
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
                            navigationLabel(section,
                                organization: s.tenant?['kind'] == 'ORGANIZATION'),
                            style:
                                const TextStyle(color: muted, fontSize: 13))),
                  if (!wide) const SizedBox(width: 8),
                  if (wide && workspacePicker != null) workspacePicker,
                  if (!wide)
                    Expanded(
                        child: Align(
                            alignment: Alignment.centerLeft,
                            child: workspacePicker)),
                  if (notifications != null)
                    NotificationShortcut(
                        key: ValueKey(('notifications', s, s.profile?['subject'],
                            s.tenant?['id'], s.role, s.scopeGeneration)),
                        repository: notifications,
                        onOpen: () {
                          if (context.mounted &&
                              identical(context.read<Session>(), s) &&
                              notifications.current()) {
                            context.go('/notifications');
                          }
                        }),
                  if (s.tenant != null && s.canOpen('help-requests'))
                    HelpShortcut(
                        key: ValueKey(('help', s, s.profile?['subject'],
                            s.tenant?['id'], s.role, s.scopeGeneration)),
                        session: s,
                        onOpen: () => context.go('/help-requests')),
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
