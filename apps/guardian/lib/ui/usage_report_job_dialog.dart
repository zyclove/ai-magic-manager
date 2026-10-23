import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/api.dart';
import '../core/usage_report_jobs.dart';
import '../core/usage_reports.dart';
import 'design.dart';
import 'owned_dialog_route.dart';

class UsageReportJobDialog extends StatefulWidget {
  final UsageReportJobRepository repository;
  final UsageReportJobDraft draft;
  final String? requestKey;
  final ValueChanged<UsageReportJob> onCreated;
  final void Function(UsageReportJobDraft, String)? onReauth;
  final Listenable? accessChanges;
  final bool Function()? hasAccess;
  const UsageReportJobDialog(
      {super.key,
      required this.repository,
      required this.draft,
      required this.onCreated,
      this.requestKey,
      this.onReauth,
      this.accessChanges,
      this.hasAccess});
  @override
  State<UsageReportJobDialog> createState() => _UsageReportJobDialogState();
}

class _UsageReportJobDialogState extends State<UsageReportJobDialog> {
  late final String requestKey = widget.requestKey ?? requestId();
  late final UsageReportJobDraft draft = widget.draft;
  bool busy = false, attempted = false, done = false, invalidated = false;
  Object? error;
  @override
  void initState() {
    super.initState();
    widget.accessChanges?.addListener(changed);
  }

  bool current(UsageReportJobRepository repository) {
    if (!mounted || invalidated || !identical(widget.repository, repository) ||
        !repository.current() || widget.hasAccess?.call() == false) return false;
    final route = ModalRoute.of(context);
    return route?.isActive == true &&
        (route is! OwnedDialogRoute<dynamic> || route.available);
  }

  @override
  void didUpdateWidget(covariant UsageReportJobDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.accessChanges, widget.accessChanges)) {
      oldWidget.accessChanges?.removeListener(changed);
      widget.accessChanges?.addListener(changed);
    }
    if (!identical(oldWidget.repository, widget.repository)) invalidated = true;
    changed();
  }

  void changed() {
    if (!mounted) return;
    setState(() {
      if (!widget.repository.current()) invalidated = true;
      if (invalidated) {
        error = null;
        busy = false;
      }
    });
  }

  void close() {
    if (!mounted || (busy && current(widget.repository))) return;
    final route = ModalRoute.of(context);
    if (route is OwnedDialogRoute<dynamic>) {
      route.finish();
    } else if (route?.isActive == true) {
      if (route!.isCurrent) {
        route.navigator!.pop();
      } else {
        route.navigator!.removeRoute(route);
      }
    }
  }

  @override
  void dispose() {
    widget.accessChanges?.removeListener(changed);
    super.dispose();
  }

  Future<void> submit() async {
    final repository = widget.repository;
    if (busy || done || !current(repository)) return;
    setState(() {
      busy = true;
      attempted = true;
      error = null;
    });
    try {
      final job = await repository.create(draft, requestKey);
      if (!current(repository)) return;
      setState(() {
        done = true;
        busy = false;
      });
      widget.onCreated(job);
    } catch (e) {
      if (current(repository)) setState(() => error = e);
    } finally {
      if (current(repository)) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowed = current(widget.repository);
    String date(int value) => DateFormat('yyyy-MM-dd HH:mm')
        .format(usageLocalTime(value, draft.timeZone));
    return PopScope(
        canPop: !busy || !allowed,
        child: AlertDialog(
            title: const Text('后台生成使用报表'),
            content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                    child: allowed
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                                Text(
                                    '${draft.deviceIds.length} 台设备 · ${draft.period == 'DAY' ? '按日' : '按周'}汇总',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                const SizedBox(height: 12),
                                Text('${date(draft.from)} 至 ${date(draft.to)}'),
                                Text('${draft.timeZone} · 包含开始时刻，不包含结束时刻。',
                                    style: const TextStyle(color: muted)),
                                const SizedBox(height: 16),
                                const Notice(
                                    '提交后可离开本页，稍后在“报表任务”查看进度。结果保留至创建后 24 小时。'),
                                const SizedBox(height: 12),
                                const Text(
                                    '创建和查看结果需要近期安全验证。当前日期只计算到提交时刻；设备授权或范围发生变化时，旧结果将失效。'),
                                if (attempted && !done) ...[
                                  const SizedBox(height: 12),
                                  const Text(
                                      '重试会沿用本次条件与请求标识。若提交结果不明确，也可关闭窗口后到任务列表查看。',
                                      style: TextStyle(color: muted)),
                                ],
                                if (error != null) ...[
                                  const SizedBox(height: 16),
                                  FailureView(error!,
                                      reauth: busy || widget.onReauth == null
                                          ? null
                                          : () {
                                              if (current(widget.repository) &&
                                                  !busy && !done) {
                                                widget.onReauth!(draft, requestKey);
                                              }
                                            }),
                                ],
                                if (done) const Notice('任务已创建。'),
                              ])
                        : const Notice('工作空间或权限已变化，请重新打开报表。', warning: true))),
            actions: [
              TextButton(
                  onPressed: busy && allowed ? null : close,
                  child: const Text('关闭')),
              if (allowed && !done)
                FilledButton(
                    onPressed: busy ? null : submit,
                    child: Text(busy
                        ? '正在提交…'
                        : attempted
                            ? '按原条件重试'
                            : '确认生成')),
            ]));
  }
}
