import 'dart:async';
import 'package:flutter/material.dart';
import '../core/notifications.dart';

/// One bounded poll while mounted, also refreshed after an acknowledged read.
class NotificationShortcut extends StatefulWidget {
  final NotificationRepository repository;
  final VoidCallback onOpen;
  const NotificationShortcut(
      {super.key, required this.repository, required this.onOpen});
  @override
  State<NotificationShortcut> createState() => _NotificationShortcutState();
}

class _NotificationShortcutState extends State<NotificationShortcut>
    with WidgetsBindingObserver {
  InboxCount? count;
  bool failed = false, busy = false;
  int generation = 0;
  Timer? timer;
  StreamSubscription<String>? changes;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    changes = NotificationRepository.changes.listen((root) {
      if (root == widget.repository.root) refresh();
    });
    schedule();
    refresh();
  }

  void schedule() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(minutes: 1), (_) => refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      schedule();
      refresh();
    } else {
      timer?.cancel();
    }
  }

  @override
  void didUpdateWidget(covariant NotificationShortcut oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      generation++;
      busy = false;
      count = null;
      refresh();
    }
  }

  Future<void> refresh() async {
    if (busy) return;
    busy = true;
    final request = ++generation;
    try {
      final result = await widget.repository.count();
      if (!mounted || generation != request) return;
      setState(() {
        count = result;
        failed = false;
      });
    } catch (_) {
      if (!mounted || generation != request) return;
      setState(() {
        count = null;
        failed = true;
      });
    } finally {
      if (generation == request) busy = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    changes?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = failed
        ? '通知中心，未读数量暂不可用'
        : count == null
            ? '通知中心'
            : '通知中心，${count!.label} 条未读';
    return IconButton(
        tooltip: label,
        onPressed: widget.onOpen,
        icon: Badge(
            isLabelVisible: failed || (count?.count ?? 0) > 0,
            label: Text(failed
                ? '!'
                : (count?.count ?? 0) > 99
                    ? '99+'
                    : '${count?.count ?? 0}'),
            child: const Icon(Icons.notifications_none_outlined)));
  }
}
