import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/api.dart';
import '../core/usage_report_jobs.dart';
import '../core/usage_reports.dart';
import 'design.dart';

class UsageReportJobDialog extends StatefulWidget {
  final UsageReportJobRepository repository;
  final UsageReportJobDraft draft;
  final String? requestKey;
  final ValueChanged<UsageReportJob> onCreated;
  final void Function(UsageReportJobDraft, String)? onReauth;
  final Listenable? accessChanges;
  const UsageReportJobDialog(
      {super.key,
      required this.repository,
      required this.draft,
      required this.onCreated,
      this.requestKey,
      this.onReauth,
      this.accessChanges});
  @override
  State<UsageReportJobDialog> createState() => _UsageReportJobDialogState();
}

class _UsageReportJobDialogState extends State<UsageReportJobDialog> {
  late final String requestKey = widget.requestKey ?? requestId();
  late final UsageReportJobDraft draft = widget.draft;
  bool busy = false, attempted = false, done = false;
  Object? error;
  @override
  void initState() {
    super.initState();
    widget.accessChanges?.addListener(changed);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.accessChanges?.removeListener(changed);
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || done || !widget.repository.current()) return;
    setState(() {
      busy = true;
      attempted = true;
      error = null;
    });
    try {
      final job = await widget.repository.create(draft, requestKey);
      if (!mounted || !widget.repository.current()) return;
      setState(() {
        done = true;
        busy = false;
      });
      widget.onCreated(job);
    } catch (e) {
      if (mounted && widget.repository.current()) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.repository.current();
    String date(int value) => DateFormat('yyyy-MM-dd HH:mm')
        .format(usageLocalTime(value, draft.timeZone));
    return PopScope(
        canPop: !busy || !current,
        child: AlertDialog(
            title: const Text('后台生成使用报表'),
            content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                    child: current
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
                                          : () => widget.onReauth!(
                                              draft, requestKey)),
                                ],
                                if (done) const Notice('任务已创建。'),
                              ])
                        : const Notice('工作空间或权限已变化，请重新打开报表。', warning: true))),
            actions: [
              TextButton(
                  onPressed: busy && current
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('关闭')),
              if (current && !done)
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
