import 'dart:async';
import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/session.dart';
import '../pages/device_subflow_scope.dart';

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
  late final Session sessionOwner;
  late final DeviceSubflowScope scope;
  late final String root;
  int? count;
  bool failed = false, busy = false, capped = false;
  int generation = 0;
  Timer? timer;

  bool permitted() =>
      mounted &&
      identical(widget.session, sessionOwner) &&
      sessionOwner.tenant != null &&
      sessionOwner.canOpen('help-requests');

  bool get current => mounted && scope.current;

  @override
  void initState() {
    super.initState();
    sessionOwner = widget.session;
    root = sessionOwner.root;
    scope = DeviceSubflowScope(sessionOwner, permitted: permitted);
    scope.addListener(accessChanged);
    WidgetsBinding.instance.addObserver(this);
    schedule();
    refresh();
  }

  @override
  void didUpdateWidget(covariant HelpShortcut oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) accessChanged();
  }

  void accessChanged() {
    if (current) return;
    generation++;
    timer?.cancel();
    timer = null;
    count = null;
    failed = false;
    busy = false;
    capped = false;
  }

  void schedule() {
    timer?.cancel();
    timer = null;
    if (!current) return;
    timer = Timer.periodic(const Duration(minutes: 1), (_) => refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      schedule();
      refresh();
    } else {
      timer?.cancel();
      timer = null;
    }
  }

  Future<void> refresh() async {
    if (!current || busy) return;
    busy = true;
    final epoch = ++generation;
    try {
      final raw = await scope.api.send('GET', '$root/help-requests/open-count');
      if (!current || generation != epoch) return;
      if (raw is! Map<String, dynamic> ||
          raw['count'] is! int ||
          raw['count'] < 0 ||
          raw['count'] > 1000 ||
          raw['capped'] is! bool) {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
      setState(() {
        count = raw['count'] as int;
        capped = raw['capped'] as bool;
        failed = false;
      });
    } catch (_) {
      if (current && generation == epoch) {
        setState(() {
          count = null;
          failed = true;
        });
      }
    } finally {
      if (generation == epoch) busy = false;
    }
  }

  void open() {
    if (current) widget.onOpen();
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    scope.removeListener(accessChanged);
    scope.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: scope,
      builder: (context, _) {
        final available = current;
        final description = failed
            ? '儿童求助数量暂不可用，打开求助记录核对'
            : count == null
                ? '儿童求助记录'
                : count == 0
                    ? '暂无待查看儿童求助'
                    : '有 ${capped ? '1000+' : count} 条儿童求助待查看';
        return IconButton(
            tooltip: description,
            onPressed: available ? open : null,
            icon: Badge(
                isLabelVisible: available && (failed || (count ?? 0) > 0),
                label: Text(failed
                    ? '!'
                    : (count ?? 0) > 99
                        ? '99+'
                        : '$count'),
                child: const Icon(Icons.volunteer_activism_outlined)));
      });
}
