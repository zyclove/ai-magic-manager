import 'package:flutter/material.dart';
import '../core/notifications.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/notifications_view.dart';

class NotificationsPage extends StatefulWidget {
  final Session session;
  final Future<void> Function(String) onOpen;
  const NotificationsPage(
      {super.key, required this.session, required this.onOpen});
  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  late final String root, role;
  late final NotificationRepository repository;
  bool current() =>
      widget.session.authenticated &&
      widget.session.tenant != null &&
      widget.session.root == root &&
      widget.session.role == role &&
      notificationRoles.contains(role);
  @override
  void initState() {
    super.initState();
    root = widget.session.root;
    role = widget.session.role;
    repository = NotificationRepository(
        api: widget.session.api, root: root, current: current);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.session,
      builder: (_, __) => current()
          ? NotificationsView(repository: repository, onOpen: widget.onOpen)
          : const Panel(
              child: EmptyView('工作空间或权限已变化', '已隐藏旧通知，请重新打开当前工作空间的通知中心。')));
}
