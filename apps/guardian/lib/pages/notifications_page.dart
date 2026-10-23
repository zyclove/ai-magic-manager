import 'package:flutter/material.dart';
import '../core/notifications.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/notifications_view.dart';
import 'device_subflow_scope.dart';

class NotificationsPage extends StatefulWidget {
  final Session session;
  final Future<void> Function(String) onOpen;
  const NotificationsPage(
      {super.key, required this.session, required this.onOpen});
  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  late final Session sessionOwner;
  late final DeviceSubflowScope scope;
  late final String root, role;
  late final NotificationRepository repository;

  bool permitted() =>
      mounted &&
      identical(widget.session, sessionOwner) &&
      sessionOwner.tenant != null &&
      notificationRoles.contains(role) &&
      sessionOwner.canOpen('notifications');

  bool current() => mounted && scope.current;

  @override
  void initState() {
    super.initState();
    sessionOwner = widget.session;
    root = sessionOwner.root;
    role = sessionOwner.role;
    scope = DeviceSubflowScope(sessionOwner, permitted: permitted);
    repository = NotificationRepository(
        api: scope.api, root: root, current: current);
  }

  Future<void> open(String requestId) async {
    if (!current()) return;
    await widget.onOpen(requestId);
  }

  @override
  void dispose() {
    scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: scope,
      builder: (_, __) => current()
          ? NotificationsView(repository: repository, onOpen: open)
          : const Panel(
              child: EmptyView('工作空间或权限已变化', '已隐藏旧通知，请重新打开当前工作空间的通知中心。')));
}
