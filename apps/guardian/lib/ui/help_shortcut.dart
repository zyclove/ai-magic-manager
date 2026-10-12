import 'dart:async';
import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/session.dart';

/// Polls only the bounded open-help count while the management console is visible.
class HelpShortcut extends StatefulWidget {
  final Session session;
  final VoidCallback onOpen;
  const HelpShortcut({super.key, required this.session, required this.onOpen});

  @override
  State<HelpShortcut> createState() => _HelpShortcutState();
}

class _HelpShortcutState extends State<HelpShortcut>
    with WidgetsBindingObserver {
  late final String root, role;
  int? count;
  bool failed = false, busy = false, capped = false;
  int generation = 0;
  Timer? timer;

  bool get current =>
      widget.session.authenticated &&
      widget.session.tenant != null &&
      widget.session.root == root &&
      widget.session.role == role &&
      widget.session.canOpen('help-requests');

  @override
  void initState() {
    super.initState();
    root = widget.session.root;
    role = widget.session.role;
    WidgetsBinding.instance.addObserver(this);
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

  Future<void> refresh() async {
    if (busy || !current) return;
    busy = true;
    final epoch = ++generation;
    try {
      final raw = await widget.session.api
          .send('GET', '$root/help-requests/open-count');
      if (raw is! Map<String, dynamic> ||
          raw['count'] is! int ||
          raw['count'] < 0 ||
          raw['count'] > 1000 ||
          raw['capped'] is! bool) {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
      if (mounted && current && generation == epoch) {
        setState(() {
          count = raw['count'] as int;
          capped = raw['capped'] as bool;
          failed = false;
        });
      }
    } catch (_) {
      if (mounted && current && generation == epoch) {
        setState(() {
          count = null;
          failed = true;
        });
      }
    } finally {
      if (generation == epoch) busy = false;
    }
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final description = failed
        ? '儿童求助数量暂不可用，打开求助记录核对'
        : count == null
            ? '儿童求助记录'
            : count == 0
                ? '暂无待查看儿童求助'
                : '有 ${capped ? '1000+' : count} 条儿童求助待查看';
    return IconButton(
        tooltip: description,
        onPressed: widget.onOpen,
        icon: Badge(
            isLabelVisible: failed || (count ?? 0) > 0,
            label: Text(failed
                ? '!'
                : (count ?? 0) > 99
                    ? '99+'
                    : '$count'),
            child: const Icon(Icons.volunteer_activism_outlined)));
  }
}
