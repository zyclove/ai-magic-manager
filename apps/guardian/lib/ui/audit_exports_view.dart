import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/audit_exports.dart';
import '../core/labels.dart';
import 'design.dart';

class AuditExportsView extends StatefulWidget {
  final AuditExportRepository repository;
  final Future<void> Function(Uint8List, String) saveFile;
  final VoidCallback onReauth, onAudit;
  final Listenable? accessChanges;
  const AuditExportsView(
      {super.key,
      required this.repository,
      required this.saveFile,
      required this.onReauth,
      required this.onAudit,
      this.accessChanges});
  @override
  State<AuditExportsView> createState() => _AuditExportsViewState();
}

class _AuditExportsViewState extends State<AuditExportsView>
    with WidgetsBindingObserver {
  AuditExportPage? page;
  Object? error;
  String? cursor, operation;
  final history = <String?>[];
  bool busy = false, foreground = true;
  int generation = 0;
  Timer? timer;
  VoidCallback? retry;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.accessChanges?.addListener(accessChanged);
    load();
  }

  void accessChanged() {
    if (!widget.repository.current()) {
      timer?.cancel();
      generation++;
      setState(() {
        page = null;
        busy = false;
        error = const ApiFailure(409, 'WORKSPACE_CHANGED');
        retry = null;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      schedule();
    } else {
      timer?.cancel();
    }
  }

  void schedule() {
    timer?.cancel();
    if (foreground &&
        !busy &&
        operation == null &&
        error == null &&
        widget.repository.current() &&
        (page?.items.any((j) => j.pending) ?? false)) {
      timer = Timer(
          const Duration(seconds: 15), () => load(target: cursor, quiet: true));
    }
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    widget.accessChanges?.removeListener(accessChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool valid(int token) =>
      mounted && token == generation && widget.repository.current();
  Future<void> load(
      {String? target,
      int direction = 0,
      bool reset = false,
      bool quiet = false}) async {
    if (operation != null || !widget.repository.current()) return;
    timer?.cancel();
    final token = ++generation;
    setState(() {
      busy = true;
      error = null;
      retry = null;
      if (!quiet) page = null;
    });
    try {
      final result = await widget.repository.load(cursor: target);
      if (!valid(token)) return;
      setState(() {
        if (reset) {
          history.clear();
        } else if (direction > 0) {
          history.add(cursor);
        } else if (direction < 0 && history.isNotEmpty) {
          history.removeLast();
        }
        cursor = target;
        page = result;
        busy = false;
      });
      schedule();
    } catch (e) {
      if (!mounted || token != generation) return;
      setState(() {
        busy = false;
        page = null;
        error = e;
        retry = widget.repository.current()
            ? () => load(target: target, direction: direction, reset: reset)
            : null;
      });
    }
  }

  Future<void> cancel(AuditExportJob job) async {
    if (busy || operation != null) return;
    timer?.cancel();
    setState(() => operation = job.id);
    final token = ++generation;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('取消这次导出？'),
                content: const Text('将停止生成并删除在线文件。已经下载到设备的副本不会被删除。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('保留任务')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确认取消'))
                ]));
    if (!valid(token)) return;
    if (confirmed != true) {
      setState(() => operation = null);
      schedule();
      return;
    }
    try {
      final result = await widget.repository.cancel(job.id);
      if (!valid(token)) return;
      setState(() {
        page = AuditExportPage(
            page!.items.map((j) => j.id == result.id ? result : j).toList(),
            page!.nextCursor);
        operation = null;
        error = null;
      });
      schedule();
    } catch (e) {
      mutationFailed(e, token);
    }
  }

  Future<void> download(AuditExportJob job) async {
    if (busy || operation != null) return;
    timer?.cancel();
    final token = ++generation;
    setState(() {
      operation = job.id;
      error = null;
      retry = null;
    });
    try {
      final bytes = await widget.repository.download(job);
      if (!valid(token)) return;
      widget.repository.ensureCurrent();
      await widget.saveFile(bytes, 'audit-${job.id}.json');
      if (!mounted || !valid(token)) return;
      setState(() => operation = null);
      toast(context, '已交给浏览器下载，请查看下载记录。');
      schedule();
    } catch (e) {
      mutationFailed(e, token);
    }
  }

  void mutationFailed(Object e, int token) {
    if (!mounted || token != generation) return;
    final denied = e is ApiFailure &&
        (e.code == 'WORKSPACE_CHANGED' ||
            e.status == 403 ||
            e.status == 401 && e.code != 'REAUTH_REQUIRED');
    setState(() {
      operation = null;
      error = e;
      retry = null;
      if (denied) page = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final disabled = busy || operation != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeading('导出任务', '查看本人在当前工作空间创建的审计导出。',
          action: IconButton(
              tooltip: '刷新导出任务',
              onPressed: disabled ? null : () => load(reset: true),
              icon: const Icon(Icons.refresh))),
      Wrap(spacing: 12, runSpacing: 8, children: [
        FilledButton.icon(
            onPressed: disabled ? null : widget.onAudit,
            icon: const Icon(Icons.add),
            label: const Text('选择日志并导出')),
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('JSON 日志 · 加密保存 · 24 小时有效',
                style: TextStyle(color: muted))),
      ]),
      const SizedBox(height: 16),
      if (error != null)
        Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Panel(
                child: FailureView(error!,
                    retry: retry, reauth: widget.onReauth))),
      if (busy && page == null)
        const Panel(
            child: Center(
                child: Padding(
                    padding: EdgeInsets.all(28),
                    child: CircularProgressIndicator()))),
      if (page != null) ...[
        if (page!.items.isEmpty)
          Panel(
              child: EmptyView('还没有导出任务', '在审计日志中应用日期和筛选条件，再选择“导出当前结果”。',
                  action: OutlinedButton(
                      onPressed: widget.onAudit, child: const Text('打开审计日志')))),
        for (final job in page!.items)
          Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Panel(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text('审计日志导出',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w600)),
                          Chip(
                              label: Text(job.title),
                              avatar: Icon(
                                  job.state == 'READY'
                                      ? Icons.check_circle_outline
                                      : job.pending
                                          ? Icons.schedule
                                          : Icons.info_outline,
                                  size: 18)),
                        ]),
                    const SizedBox(height: 8),
                    Text(job.description,
                        style: const TextStyle(color: muted, height: 1.6)),
                    const SizedBox(height: 16),
                    Text(
                        '${dateLabel(job.selection.from)} 至 ${dateLabel(job.selection.to)}'),
                    const SizedBox(height: 6),
                    Text(
                        '创建于 ${dateLabel(job.createdAt)} · 到期 ${dateLabel(job.expiresAt)}',
                        style: const TextStyle(color: muted, fontSize: 12)),
                    if (job.selection.action != null)
                      Text('操作：${job.selection.action}'),
                    if (job.selection.resourceId != null)
                      SelectableText('资源：${job.selection.resourceId}'),
                    if (job.selection.correlationId != null)
                      SelectableText('关联：${job.selection.correlationId}'),
                    if (job.state == 'READY')
                      Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                              '${job.recordCount} 条记录 · ${(job.byteCount! / 1024).toStringAsFixed(1)} KiB')),
                    const SizedBox(height: 12),
                    SelectableText('任务编号 ${job.id}',
                        style: const TextStyle(color: muted, fontSize: 11)),
                    if (job.cancellable)
                      Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Wrap(spacing: 12, runSpacing: 8, children: [
                            if (job.state == 'READY')
                              FilledButton.icon(
                                  onPressed:
                                      disabled ? null : () => download(job),
                                  icon: const Icon(Icons.download_outlined),
                                  label: const Text('下载 JSON')),
                            OutlinedButton(
                                onPressed: disabled ? null : () => cancel(job),
                                child: const Text('取消导出')),
                            if (operation == job.id)
                              const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Text('正在处理…',
                                      style: TextStyle(color: muted))),
                          ])),
                  ]))),
        if (page!.items.isNotEmpty)
          Wrap(spacing: 12, runSpacing: 8, children: [
            OutlinedButton(
                onPressed: disabled || history.isEmpty
                    ? null
                    : () => load(target: history.last, direction: -1),
                child: const Text('上一页')),
            OutlinedButton(
                onPressed: disabled || page!.nextCursor == null
                    ? null
                    : () => load(target: page!.nextCursor, direction: 1),
                child: const Text('下一页')),
            Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                    '第 ${history.length + 1} 页 · 本页 ${page!.items.length} 项',
                    style: const TextStyle(color: muted))),
          ]),
        if (page!.items.any((j) => j.pending))
          const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('生成中的任务每 15 秒自动更新。',
                  style: TextStyle(color: muted, fontSize: 12))),
      ]
    ]);
  }
}
