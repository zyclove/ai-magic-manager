import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/audit.dart';
import '../core/labels.dart';
import 'design.dart';

class AuditView extends StatefulWidget {
  final AuditRepository repository;
  final Listenable? accessChanges;
  final ValueChanged<AuditQuery>? onExport;
  const AuditView(
      {super.key, required this.repository, this.accessChanges, this.onExport});
  @override
  State<AuditView> createState() => _AuditViewState();
}

class _AuditViewState extends State<AuditView> {
  final form = GlobalKey<FormState>();
  final action = TextEditingController(),
      resource = TextEditingController(),
      trace = TextEditingController();
  late DateTimeRange range;
  late AuditQuery applied;
  AuditPage? page;
  String? cursor;
  final history = <String?>[];
  Object? error;
  VoidCallback? retry;
  bool busy = false, opening = false;
  int generation = 0;
  bool recent = true;
  @override
  void initState() {
    super.initState();
    resetRange();
    applied = query();
    load();
  }

  void resetRange() {
    final end = DateTime.now();
    range =
        DateTimeRange(start: end.subtract(const Duration(days: 7)), end: end);
    recent = true;
  }

  String? value(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();
  AuditQuery query() => AuditQuery(
      from: range.start.millisecondsSinceEpoch,
      to: range.end.millisecondsSinceEpoch,
      action: value(action),
      resourceId: value(resource),
      correlationId: value(trace));
  Future<void> load(
      {String? target, int direction = 0, bool refresh = false}) async {
    final ticket = ++generation;
    if (refresh) {
      if (recent) resetRange();
      applied = query();
      history.clear();
      cursor = null;
    }
    final destination = refresh ? null : target;
    setState(() {
      busy = true;
      error = null;
      retry = null;
      page = null;
    });
    try {
      final result = await widget.repository.load(applied, cursor: destination);
      if (!mounted || ticket != generation) return;
      setState(() {
        if (direction > 0) history.add(cursor);
        if (direction < 0 && history.isNotEmpty) history.removeLast();
        cursor = destination;
        page = result;
      });
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(() {
          error = e;
          retry = () => load(target: destination, direction: direction);
        });
      }
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  Future<void> open(AuditEvent row) async {
    if (opening || busy) return;
    setState(() => opening = true);
    try {
      final item = await widget.repository.detail(row.id);
      if (!mounted) return;
      await actionDetails(
          context,
          '审计事件详情',
          {
            '操作': label(item.action),
            '操作代码': item.action,
            '发生时间': DateFormat('yyyy-MM-dd HH:mm:ss.SSS')
                .format(DateTime.fromMillisecondsSinceEpoch(item.occurredAt)),
            '显示时区': DateTime.fromMillisecondsSinceEpoch(item.occurredAt)
                .timeZoneName,
            '操作者标识': item.actorId,
            '资源编号': item.resourceId,
            '关联编号': item.correlationId,
            '事件编号': item.id,
          },
          accessChanges: widget.accessChanges,
          hasAccess: widget.repository.current);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e;
          page = null;
          retry = () => load(target: cursor);
        });
      }
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  Future<void> dates() async {
    final now = DateTime.now();
    final chosen = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: now,
        initialDateRange: DateTimeRange(
            start: range.start,
            end: range.end.subtract(const Duration(milliseconds: 1))),
        helpText: '选择审计日期范围',
        saveText: '确定');
    if (!mounted || chosen == null) return;
    final end = DateTime(chosen.end.year, chosen.end.month, chosen.end.day + 1);
    if (end.difference(chosen.start) > const Duration(days: 366)) {
      toast(context, '一次最多查询 366 天，请缩小日期范围。');
      return;
    }
    setState(() {
      range = DateTimeRange(start: chosen.start, end: end);
      recent = false;
    });
  }

  @override
  void dispose() {
    generation++;
    action.dispose();
    resource.dispose();
    trace.dispose();
    super.dispose();
  }

  String? idError(String? s) =>
      s == null || s.trim().isEmpty || auditUuid.hasMatch(s.trim())
          ? null
          : '请输入完整的小写 UUID 编号';
  String? resourceError(String? s) =>
      s == null || s.trim().isEmpty || auditResourceId(s.trim())
          ? null
          : '请输入详情中的完整资源编号';
  @override
  Widget build(BuildContext context) {
    final disabled = busy || opening;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final start = DateFormat('yyyy-MM-dd').format(range.start),
        end = DateFormat('yyyy-MM-dd')
            .format(range.end.subtract(const Duration(milliseconds: 1)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PageHeading('审计日志', '追溯管理操作、资源变更与请求记录。',
          action: IconButton(
              tooltip: '刷新审计日志',
              onPressed: disabled
                  ? null
                  : () {
                      if (form.currentState!.validate()) load(refresh: true);
                    },
              icon: const Icon(Icons.refresh))),
      Panel(
          child: Form(
              key: form,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          OutlinedButton.icon(
                              onPressed: disabled ? null : dates,
                              icon: const Icon(Icons.date_range_outlined),
                              label: Text(recent ? '最近 7 天' : '$start — $end')),
                          Text('时间按本机时区 ${DateTime.now().timeZoneName} 显示',
                              style:
                                  const TextStyle(color: muted, fontSize: 12)),
                        ]),
                    const SizedBox(height: 16),
                    LayoutBuilder(builder: (_, constraints) {
                      final width = compact
                          ? constraints.maxWidth
                          : (constraints.maxWidth - 24) / 3;
                      return Wrap(spacing: 12, runSpacing: 16, children: [
                        SizedBox(
                            width: width,
                            child: TextFormField(
                                key: const Key('audit-action'),
                                controller: action,
                                enabled: !disabled,
                                maxLength: 100,
                                decoration: const InputDecoration(
                                    labelText: '操作代码',
                                    hintText: '如 SUBJECT_CREATED',
                                    counterText: ''),
                                validator: (v) => v == null ||
                                        v.trim().isEmpty ||
                                        RegExp(r'^[A-Z][A-Z0-9_]{0,99}$')
                                            .hasMatch(v.trim())
                                    ? null
                                    : '请使用大写字母、数字和下划线')),
                        SizedBox(
                            width: width,
                            child: TextFormField(
                                controller: resource,
                                enabled: !disabled,
                                maxLength: 100,
                                decoration: const InputDecoration(
                                    labelText: '资源编号',
                                    hintText: '完整编号，可从详情复制',
                                    counterText: ''),
                                validator: resourceError)),
                        SizedBox(
                            width: width,
                            child: TextFormField(
                                controller: trace,
                                enabled: !disabled,
                                maxLength: 36,
                                decoration: const InputDecoration(
                                    labelText: '关联编号',
                                    hintText: '定位同一次请求',
                                    counterText: ''),
                                validator: idError)),
                      ]);
                    }),
                    const SizedBox(height: 16),
                    Wrap(spacing: 12, children: [
                      if (widget.onExport != null)
                        OutlinedButton.icon(
                            onPressed: disabled || page == null
                                ? null
                                : () => widget.onExport!(applied),
                            icon: const Icon(Icons.download_outlined, size: 18),
                            label: const Text('导出当前结果')),
                      FilledButton.icon(
                          onPressed: disabled
                              ? null
                              : () {
                                  if (form.currentState!.validate()) {
                                    load(refresh: true);
                                  }
                                },
                          icon: const Icon(Icons.search, size: 18),
                          label: const Text('应用筛选')),
                      TextButton(
                          onPressed: disabled
                              ? null
                              : () {
                                  action.clear();
                                  resource.clear();
                                  trace.clear();
                                  resetRange();
                                  form.currentState!.reset();
                                  load(refresh: true);
                                },
                          child: const Text('重置'))
                    ]),
                  ]))),
      const SizedBox(height: 20),
      const Text('最新记录优先 · 每页最多 20 条 · 筛选后点击“应用筛选”',
          style: TextStyle(color: muted, fontSize: 12)),
      const SizedBox(height: 12),
      if (busy)
        const Panel(
            child: Center(
                child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator()))),
      if (error != null) Panel(child: FailureView(error!, retry: retry)),
      if (page != null && page!.items.isEmpty)
        const Panel(
            child: EmptyView('没有符合条件的审计记录', '可扩大日期范围或清除筛选。新的管理操作会记录在这里。')),
      if (page != null && page!.items.isNotEmpty)
        Panel(
            child: Column(children: [
          for (final row in page!.items) ...[
            ListTile(
                contentPadding: EdgeInsets.zero,
                isThreeLine: true,
                title: Text(label(row.action),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                    '${dateLabel(row.occurredAt)}\n资源 ${shortId(row.resourceId)}'),
                trailing: TextButton(
                    onPressed: disabled ? null : () => open(row),
                    child: const Text('查看详情'))),
            if (row != page!.items.last) const Divider(height: 1),
          ]
        ])),
      if (page != null)
        Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton(
                      onPressed: disabled || history.isEmpty
                          ? null
                          : () => load(target: history.last, direction: -1),
                      child: const Text('上一页')),
                  Text('第 ${history.length + 1} 页 · ${page!.items.length} 条'),
                  OutlinedButton(
                      onPressed: disabled || page!.nextCursor == null
                          ? null
                          : () => load(target: page!.nextCursor, direction: 1),
                      child: const Text('下一页')),
                ])),
      const SizedBox(height: 16),
      const Notice('记录反映服务端已记录的操作，不代表设备已执行。此页面为只读查询。'),
    ]);
  }
}
