import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/api.dart';
import '../core/application_classification.dart';
import '../core/usage_report_jobs.dart';
import '../core/usage_reports.dart';
import 'design.dart';
import 'usage_reports_view.dart';

class UsageReportJobsView extends StatefulWidget {
  final UsageReportJobRepository repository;
  final Future<UsageReportTarget> Function(UsageReportJobPart) resolveTarget;
  final Future<List<UsageReportTarget>> Function()? loadTargets;
  final Future<void> Function(Uint8List bytes, String filename)? saveFile;
  final Listenable? accessChanges;
  final VoidCallback? reauth, onQuery;
  final int Function()? clock;
  const UsageReportJobsView(
      {super.key,
      required this.repository,
      required this.resolveTarget,
      this.loadTargets,
      this.saveFile,
      this.accessChanges,
      this.reauth,
      this.onQuery,
      this.clock});
  @override
  State<UsageReportJobsView> createState() => _UsageReportJobsViewState();
}

class _UsageReportJobsViewState extends State<UsageReportJobsView>
    with WidgetsBindingObserver {
  UsageReportJobPage? page;
  UsageReport? report;
  UsageReportJob? reportJob;
  Object? error;
  String? message;
  String? cursor, dialogJobId;
  final history = <String?>[];
  String category = 'ALL';
  bool busy = false, foreground = true;
  int generation = 0;
  Timer? timer;
  ModalRoute<dynamic>? dialog;
  int get now => widget.clock?.call() ?? DateTime.now().millisecondsSinceEpoch;
  bool get current => mounted && foreground && widget.repository.current();
  bool available(UsageReportJob job) => job.ready && now < job.expiresAt;
  @override
  void initState() {
    super.initState();
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.accessChanges?.addListener(accessChanged);
    if (foreground) load();
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    closeDialog();
    WidgetsBinding.instance.removeObserver(this);
    widget.accessChanges?.removeListener(accessChanged);
    super.dispose();
  }

  void closeDialog() {
    final route = dialog;
    dialog = null;
    dialogJobId = null;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) {
        if (route.isCurrent) {
          route.navigator!.pop();
        } else {
          route.navigator!.removeRoute(route);
        }
      }
    });
  }

  void clearPrivate() {
    report = null;
    reportJob = null;
    category = 'ALL';
    message = null;
  }

  void accessChanged() {
    if (!widget.repository.current() && mounted) {
      generation++;
      timer?.cancel();
      closeDialog();
      setState(() {
        page = null;
        clearPrivate();
        error = null;
        busy = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    generation++;
    timer?.cancel();
    closeDialog();
    if (mounted) {
      setState(() {
        clearPrivate();
        busy = false;
      });
    }
    if (current) load();
  }

  void schedule() {
    timer?.cancel();
    if (!current || error != null) return;
    final jobs =
        page?.items.where((j) => j.cancellable && j.expiresAt > now).toList() ??
            [];
    if (jobs.isEmpty && reportJob == null) return;
    var delay = 5000;
    for (final job in jobs) {
      final remaining = job.expiresAt - now;
      if (remaining > 0 && remaining < delay) delay = remaining;
    }
    timer = Timer(Duration(milliseconds: delay), () {
      if (!current) return;
      if (reportJob != null && !available(reportJob!)) setState(clearPrivate);
      if (dialogJobId != null &&
          page!.items.any((j) => j.id == dialogJobId && j.expiresAt <= now)) {
        closeDialog();
      }
      load(quiet: true);
    });
  }

  Future<void> load({bool quiet = false}) async {
    if (!current || busy) return;
    final revision = ++generation;
    timer?.cancel();
    setState(() {
      busy = true;
      error = null;
      if (!quiet) clearPrivate();
    });
    try {
      final value = await widget.repository.load(cursor: cursor);
      UsageReportJob? checked;
      if (reportJob != null) {
        checked = await widget.repository.get(reportJob!.id);
      }
      if (!current || revision != generation) return;
      setState(() {
        page = value;
        if (reportJob != null && (checked == null || !available(checked))) {
          clearPrivate();
        }
      });
      if (dialogJobId != null &&
          !value.items.any((j) => j.id == dialogJobId && available(j))) {
        closeDialog();
      }
    } catch (e) {
      if (current && revision == generation) {
        closeDialog();
        setState(() {
          error = e;
          clearPrivate();
        });
      }
    } finally {
      if (mounted && revision == generation) {
        setState(() => busy = false);
        // A failed refresh needs an explicit retry; do not hammer an unavailable service.
        if (error == null) schedule();
      }
    }
  }

  Future<void> chooseResult(UsageReportJob job) async {
    if (busy || !current || !available(job)) return;
    final names = <String, String>{};
    if (widget.loadTargets != null) {
      timer?.cancel();
      final revision = ++generation;
      setState(() {
        busy = true;
        error = null;
        clearPrivate();
      });
      try {
        final targets = await widget.loadTargets!();
        if (!current || revision != generation) return;
        if (targets.any((t) => !t.valid) ||
            targets.map((t) => t.deviceId).toSet().length != targets.length) {
          throw const ApiFailure(502, 'INVALID_USAGE_REPORT_RESPONSE');
        }
        final index = {for (final target in targets) target.deviceId: target};
        for (final part in job.parts) {
          final target = index[part.deviceId];
          if (target == null ||
              target.registrationId != part.registrationId ||
              target.subjectId != part.subjectId) {
            throw const ApiFailure(409, 'REPORT_SCOPE_CHANGED');
          }
          names[part.deviceId] = target.displayName;
        }
      } catch (e) {
        if (current && revision == generation) setState(() => error = e);
        return;
      } finally {
        if (mounted && revision == generation) {
          setState(() => busy = false);
          schedule();
        }
      }
    }
    if (!mounted || !current || !available(job)) return;
    String search = '';
    dialogJobId = job.id;
    final part = await showDialog<UsageReportJobPart>(
        context: context,
        builder: (context) {
          dialog = ModalRoute.of(context);
          return StatefulBuilder(builder: (context, update) {
            final visible = job.parts
                .where((p) =>
                    '${names[p.deviceId] ?? ''} ${p.deviceId} ${p.subjectId}'
                        .toLowerCase()
                        .contains(search))
                .toList();
            return AlertDialog(
                semanticLabel: '选择结果设备',
                title: const Text('选择结果设备'),
                content: SizedBox(
                    width: 480,
                    height: 320,
                    child: Column(children: [
                      TextField(
                          decoration: const InputDecoration(
                              labelText: '搜索结果设备',
                              prefixIcon: Icon(Icons.search)),
                          onChanged: (value) => update(
                              () => search = value.trim().toLowerCase())),
                      const SizedBox(height: 8),
                      Expanded(
                          child: visible.isEmpty
                              ? const Center(child: Text('没有匹配的设备'))
                              : ListView.builder(
                                  itemCount: visible.length,
                                  itemBuilder: (context, index) {
                                    final part = visible[index];
                                    return Semantics(
                                        button: true,
                                        child: ListTile(
                                            leading: const Icon(
                                                Icons.devices_outlined),
                                            title: Text(
                                                '${names[part.deviceId] ?? '设备 ${part.ordinal + 1}'} · ${part.deviceId.substring(0, 8)}'),
                                            subtitle: Text(
                                                '档案 ${part.subjectId.substring(0, 8)} · ${part.usageEnabled ? '已授权用量' : '未开启用量观察'}'),
                                            trailing:
                                                const Icon(Icons.chevron_right),
                                            onTap: () =>
                                                Navigator.pop(context, part)));
                                  }))
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'))
                ]);
          });
        });
    dialog = null;
    dialogJobId = null;
    if (part != null && current) openResult(job.id, part.ordinal);
  }

  Future<void> openResult(String id, int ordinal) async {
    if (!current) return;
    timer?.cancel();
    final revision = ++generation;
    setState(() {
      busy = true;
      error = null;
      clearPrivate();
    });
    try {
      final job = await widget.repository.get(id);
      if (!current || revision != generation) return;
      if (!available(job)) throw const ApiFailure(409, 'REPORT_JOB_NOT_READY');
      final part = job.parts[ordinal];
      final target = await widget.resolveTarget(part);
      if (!current || revision != generation) return;
      final result = await widget.repository.result(job, part, target);
      if (!current || revision != generation) return;
      if (!available(job)) throw const ApiFailure(409, 'REPORT_JOB_NOT_READY');
      setState(() {
        report = result;
        reportJob = job;
      });
    } catch (e) {
      if (current && revision == generation) setState(() => error = e);
    } finally {
      if (mounted && revision == generation) {
        setState(() => busy = false);
        schedule();
      }
    }
  }

  Future<void> cancel(UsageReportJob job) async {
    if (!current || busy) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) {
          dialog = ModalRoute.of(context);
          return AlertDialog(
              title: const Text('取消这份报表任务？'),
              content: const Text('取消后将删除已生成的在线结果。需要时可重新选择范围生成。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('保留任务')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('确认取消'))
              ]);
        });
    dialog = null;
    if (confirmed != true || !current) return;
    timer?.cancel();
    final revision = ++generation;
    setState(() {
      busy = true;
      error = null;
      clearPrivate();
    });
    try {
      await widget.repository.cancel(job.id);
    } catch (e) {
      if (current && revision == generation) setState(() => error = e);
    } finally {
      if (mounted && revision == generation) {
        setState(() => busy = false);
        if (error == null && current) await load();
      }
    }
  }

  Future<void> download() async {
    if (!current ||
        busy ||
        report == null ||
        reportJob == null ||
        widget.saveFile == null) return;
    final id = reportJob!.id, device = report!.devices.single.deviceId;
    timer?.cancel();
    final revision = ++generation;
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      final job = await widget.repository.get(id);
      if (!current || revision != generation) return;
      if (!available(job)) throw const ApiFailure(409, 'REPORT_JOB_NOT_READY');
      final part = job.parts.firstWhere((p) => p.deviceId == device);
      final target = await widget.resolveTarget(part);
      if (!current || revision != generation) return;
      final bytes = await widget.repository.download(job, part, target);
      if (!current || revision != generation) return;
      if (!available(job)) throw const ApiFailure(409, 'REPORT_JOB_NOT_READY');
      await widget.saveFile!(bytes, 'usage-report-$id-$device.json');
      if (current && revision == generation) {
        setState(() => message = '已交给浏览器下载，请查看浏览器的下载记录。');
      }
    } catch (e) {
      if (current && revision == generation) {
        setState(() {
          error = e;
          clearPrivate();
        });
      }
    } finally {
      if (mounted && revision == generation) {
        setState(() => busy = false);
        schedule();
      }
    }
  }

  void navigate(String? next, {bool previous = false}) {
    if (busy) return;
    closeDialog();
    if (previous) {
      cursor = history.removeLast();
    } else {
      history.add(cursor);
      cursor = next;
    }
    setState(() {
      page = null;
      clearPrivate();
    });
    load();
  }

  String date(int value, String zone) =>
      DateFormat('MM-dd HH:mm').format(usageLocalTime(value, zone));
  @override
  Widget build(BuildContext context) {
    if (!widget.repository.current()) {
      return const Panel(child: Notice('工作空间或权限已变化，请重新打开报表。'));
    }
    if (!foreground) return const Panel(child: Notice('返回页面后将重新检查任务状态。'));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeading('报表任务', '查看当前账号创建的任务。离开页面不影响后台生成。',
          action: widget.onQuery == null
              ? null
              : OutlinedButton.icon(
                  onPressed: widget.onQuery,
                  icon: const Icon(Icons.add),
                  label: const Text('新建报表'))),
      const Notice('每份结果保留 24 小时；设备授权或范围变化后可能提前失效。结果反映各设备生成时的数据与配置。'),
      const SizedBox(height: 12),
      Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
              onPressed: busy ? null : () => load(),
              icon: const Icon(Icons.refresh),
              label: const Text('刷新任务'))),
      if (busy) const LinearProgressIndicator(),
      if (error != null)
        Panel(
            child: FailureView(error!,
                retry: busy ? null : () => load(), reauth: widget.reauth)),
      if (page?.items.isEmpty == true)
        const Panel(child: EmptyView('暂无报表任务', '在使用报表中选择设备与日期，然后点击“后台生成”。')),
      for (final job in page?.items ?? <UsageReportJob>[])
        Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Panel(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                            job.expiresAt <= now && job.cancellable
                                ? '已到期'
                                : job.title,
                            style: Theme.of(context).textTheme.titleMedium),
                        Text('${job.completedDevices} / ${job.totalDevices} 台'),
                        Text(job.selection.period == 'DAY' ? '按日' : '按周'),
                      ]),
                  const SizedBox(height: 8),
                  Text(
                      '${date(job.selection.from, job.selection.timeZone)} 至 ${date(job.selection.to, job.selection.timeZone)} · ${job.selection.timeZone}'),
                  Text(
                      '创建 ${date(job.createdAt, job.selection.timeZone)} · 到期 ${date(job.expiresAt, job.selection.timeZone)}',
                      style: const TextStyle(color: muted)),
                  if (job.pending && job.expiresAt > now)
                    Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator(
                            value: job.completedDevices / job.totalDevices,
                            semanticsLabel: '报表生成进度',
                            semanticsValue:
                                '${job.completedDevices} / ${job.totalDevices} 台')),
                  if (job.failureCode != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(ApiFailure(409, job.failureCode!).message)),
                  Wrap(spacing: 8, children: [
                    if (available(job))
                      TextButton.icon(
                          onPressed: busy ? null : () => chooseResult(job),
                          icon: const Icon(Icons.bar_chart_outlined),
                          label: const Text('查看结果')),
                    if (job.cancellable && job.expiresAt > now)
                      TextButton(
                          onPressed: busy ? null : () => cancel(job),
                          child: const Text('取消任务')),
                  ]),
                ]))),
      if (history.isNotEmpty || page?.nextCursor != null)
        Wrap(spacing: 12, children: [
          TextButton(
              onPressed: busy || history.isEmpty
                  ? null
                  : () => navigate(null, previous: true),
              child: const Text('上一页')),
          Text('第 ${history.length + 1} 页'),
          TextButton(
              onPressed: busy || page?.nextCursor == null
                  ? null
                  : () => navigate(page!.nextCursor),
              child: const Text('下一页')),
        ]),
      if (report != null) ...[
        const SizedBox(height: 20),
        Text('已保存的设备报表', style: Theme.of(context).textTheme.titleLarge),
        Text(
            '生成于 ${date(report!.generatedAt, report!.timeZone)} · ${report!.timeZone}'),
        const Notice('以下为生成时的规则与配置。设备报告未经独立验证；缺失记录不会作为零使用处理。'),
        if (widget.saveFile != null) ...[
          Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                  onPressed: busy ? null : download,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('下载本设备 JSON'))),
          const Text('文件包含本设备的完整报表，不受当前类别筛选影响。任务取消或到期不会删除已下载副本。',
              style: TextStyle(color: muted)),
          if (message != null) Notice(message!),
        ],
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
            value: category,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '结果内应用类别'),
            items: [
              const DropdownMenuItem(value: 'ALL', child: Text('全部类别')),
              for (final entry in applicationCategories.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value))
            ],
            onChanged: (value) => setState(() => category = value!)),
        const SizedBox(height: 12),
        UsageReportDeviceView(
            key: ValueKey(
                '${reportJob!.id}-${report!.devices.single.deviceId}-$category'),
            device: report!.devices.single,
            report: report!,
            historical: true,
            categoryFilter: category),
        TextButton(
            onPressed: () => setState(clearPrivate), child: const Text('收起结果')),
      ],
    ]);
  }
}
