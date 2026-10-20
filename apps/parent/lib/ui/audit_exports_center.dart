import 'operation_result_terminal_panel.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/audit.dart';
import '../core/audit_exports.dart';
import '../core/audit_export_destination.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';

class AuditExportsCenter extends StatefulWidget {
  final ParentSession session;
  final AuditQuery query;
  final AuditExportStore? store;
  final AuditExportDestination destination;
  final ParentAuditExports? repository;
  const AuditExportsCenter(
      {super.key,
      required this.session,
      required this.query,
      this.store,
      this.repository,
      this.destination = const AuditExportDestination()});
  @override
  State<AuditExportsCenter> createState() => _AuditExportsCenterState();
}

class _AuditExportsCenterState extends State<AuditExportsCenter>
    with WidgetsBindingObserver {
  late final String tenant, actor, role;
  late int generation;
  late final ParentAuditExports repository;
  late final AuditExportOperation operation;
  AuditExportPage? page;
  AuditExportJob? selected;
  Object? error;
  VoidCallback? retry;
  String? message, cursor;
  final history = <String?>[];
  bool saving = false;
  bool foreground = true,
      busy = false,
      authenticating = false,
      picking = false,
      invalidated = false;
  int epoch = 0;
  Timer? poll;
  Completer<void>? resumed;
  Route<dynamic>? dialog;
  ParentSession get session => widget.session;
  bool get sameScope =>
      mounted &&
      !_operationOwnerLost &&
      session.authenticated &&
      session.tenant?['id'] == tenant &&
      session.profile?['subject'] == actor &&
      session.role == role &&
      auditRoles.contains(role);
  bool get current =>
      !invalidated &&
      sameScope &&
      (authenticating || session.generation == generation);
  bool get available => current && foreground && !authenticating;

  bool _operationOwnerLost = false;
  @override
  void deactivate() {
    _operationOwnerLost = true;
    super.deactivate();
  }

  @override
  void initState() {
    super.initState();
    tenant = session.tenant?['id'] ?? '';
    actor = session.profile?['subject'] ?? '';
    role = session.role;
    generation = session.generation;
    repository = widget.repository ??
        ParentAuditExports(
            api: session.api,
            tenant: tenant,
            current: () => available,
            token: session.token);
    operation = AuditExportOperation(
        repository: repository,
        store: widget.store ?? AuditExportStore(),
        actor: actor,
        current: () => available);
    session.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    if (available) {
      operation.load();
      _load();
    }
  }

  void _closeDialog() {
    if (dialog?.isActive == true) dialog!.navigator?.removeRoute(dialog!);
    dialog = null;
  }

  void _abort() {
    unawaited(widget.destination.abort().catchError((Object _) {}));
  }

  void _changed() {
    if (current) return;
    invalidated = true;
    epoch++;
    poll?.cancel();
    page = null;
    selected = null;
    operation.suspend();
    _abort();
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _closeDialog();
      final route = ModalRoute.of(context);
      if (route?.isActive == true && route?.isFirst == false) {
        route!.navigator?.removeRoute(route);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (active == foreground) return;
    foreground = active;
    epoch++;
    poll?.cancel();
    _closeDialog();
    page = null;
    selected = null;
    error = null;
    operation.suspend();
    if (!active) {
      resumed ??= Completer<void>();
      if (!picking && !authenticating) _abort();
      if (!picking && !authenticating && !saving && !operation.busy) {
        busy = false;
      }
    } else {
      resumed?.complete();
      resumed = null;
      if (available && !busy) {
        operation.load();
        _load(reset: true);
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    invalidated = true;
    epoch++;
    poll?.cancel();
    resumed?.complete();
    _abort();
    session.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    operation.dispose();
    if (widget.repository == null) repository.close();
    super.dispose();
  }

  Future<bool> _foreground() async {
    if (!foreground) {
      try {
        await resumed?.future.timeout(const Duration(seconds: 30));
      } on TimeoutException {
        return false;
      }
    }
    return available;
  }

  Future<bool> _auth() async {
    if (!available) return false;
    authenticating = true;
    epoch++;
    poll?.cancel();
    setState(() {});
    bool verified = false;
    try {
      verified = await session.reauthenticate();
    } finally {
      if (verified && !invalidated && sameScope) {
        generation = session.generation;
      }
      authenticating = false;
      if (!current) _changed();
      if (mounted) setState(() {});
    }
    return verified && await _foreground();
  }

  Future<bool> _confirm(String title, String body, String action) async {
    if (!available) return false;
    final route = DialogRoute<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(title),
                content: SingleChildScrollView(child: Text(body)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('返回')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(action))
                ]));
    dialog = route;
    final answer = await Navigator.of(context).push(route);
    if (identical(dialog, route)) dialog = null;
    return answer == true && available;
  }

  String time(int n) {
    final d = DateTime.fromMillisecondsSinceEpoch(n);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  String selection(AuditQuery q) =>
      '${time(q.from)} 至 ${time(q.to)}（不含结束时刻）\n本机时区 ${DateTime.now().timeZoneName}${q.action == null ? '' : '\n操作：${auditActionName(q.action!)}'}${q.resourceId == null ? '' : '\n对象：${q.resourceId}'}${q.correlationId == null ? '' : '\n请求：${q.correlationId}'}';

  Future<void> _load(
      {String? target, int direction = 0, bool reset = false}) async {
    if (!available || busy) return;
    if (reset) {
      history.clear();
      cursor = null;
      selected = null;
      target = null;
    }
    final ticket = ++epoch;
    poll?.cancel();
    setState(() {
      busy = true;
      error = null;
      page = null;
      retry = null;
    });
    try {
      final value = await repository.list(cursor: target);
      if (available && ticket == epoch) {
        setState(() {
          if (direction > 0) history.add(cursor);
          if (direction < 0 && history.isNotEmpty) history.removeLast();
          cursor = target;
          page = value;
        });
      }
    } catch (e) {
      if (available && ticket == epoch) {
        error = e;
        retry = () => _load(target: target, direction: direction);
      }
    } finally {
      if (mounted && ticket == epoch) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> _open(String id, {bool polling = false}) async {
    if (!available || busy) return;
    final ticket = ++epoch;
    poll?.cancel();
    setState(() {
      busy = true;
      error = null;
      if (!polling) selected = null;
    });
    try {
      final value = await repository.get(id);
      if (available && ticket == epoch) {
        setState(() => selected = value);
        if (value.pending) {
          poll =
              Timer(const Duration(seconds: 5), () => _open(id, polling: true));
        }
      }
    } catch (e) {
      if (available && ticket == epoch) {
        setState(() {
          error = e;
          page = null;
          selected = null;
          retry = () => _open(id);
        });
      }
    } finally {
      if (mounted && ticket == epoch) setState(() => busy = false);
    }
  }

  Future<void> _create() async {
    if (!available ||
        busy ||
        operation.busy ||
        operation.pending != null ||
        !operation.loaded) return;
    if (!await _confirm(
        '生成这份操作记录？',
        '${selection(widget.query)}\n\nJSON 格式，最多 10,000 条、8 MiB。创建后 24 小时内可下载；文件含操作者和对象标识，仅本人可在平台下载。',
        '验证并生成')) return;
    setState(() => busy = true);
    try {
      if (!await _auth()) return;
      await operation.create(widget.query);
      if (available) selected = operation.result;
    } catch (e) {
      if (available) error = e;
    } finally {
      if (mounted) setState(() => busy = false);
      _armPoll();
      if (available && selected == null && page == null && error == null) {
        _load(reset: true);
      }
    }
  }

  Future<void> _cancel(AuditExportJob job) async {
    if (!available || busy || operation.pending != null || operation.busy) {
      return;
    }
    if (!await _confirm('取消这份导出？', '将停止生成并清除在线文件。已经保存的副本不会被删除。', '确认取消')) {
      return;
    }
    setState(() => busy = true);
    poll?.cancel();
    try {
      await operation.cancel(job.id);
      if (available) selected = operation.result;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _recover() async {
    await operation.recover();
    if (available) {
      setState(() => selected = operation.result);
      _armPoll();
    }
  }

  void _armPoll() {
    poll?.cancel();
    if (available && selected?.pending == true) {
      final id = selected!.id;
      poll = Timer(const Duration(seconds: 5), () => _open(id, polling: true));
    }
  }

  Future<void> _clear() async {
    if (!available || busy || !operation.queried) return;
    final unresolved = operation.result == null;
    if (!await _confirm(
        '完成此次核对？',
        unresolved
            ? '查询不到不代表没有提交。请先核对本人的导出列表与操作记录，再清除本机提醒。此操作不删除云端任务，也不重新生成。'
            : '当前任务状态已读取。清除本机提醒不会取消或重新生成导出。',
        '已核对，清除提醒')) return;
    if (await operation.clear() && available) _load(reset: true);
  }

  Future<void> _save(AuditExportJob job) async {
    if (!available || busy || operation.busy || job.state != 'READY') return;
    if (!await _confirm(
        '保存操作记录文件？',
        '文件包含操作者和对象标识。请选择可信的保存位置；如选择云盘，文件将由该提供方处理。取消在线导出不会删除已保存副本。',
        '验证并选择位置')) return;
    poll?.cancel();
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    Uint8List? bytes;
    saving = true;
    bool done = false;
    try {
      if (!await _auth()) return;
      picking = true;
      String? destination;
      try {
        destination = await widget.destination.choose(job.id);
      } finally {
        picking = false;
      }
      if (destination == null) {
        if (available) message = '已取消保存。';
        return;
      }
      if (!await _foreground()) return;
      final ticket = epoch;
      bool valid() => available && ticket == epoch;
      final fresh = await repository.get(job.id);
      if (!valid()) return;
      bytes = await repository.download(fresh, operation: valid);
      if (!valid()) return;
      await widget.destination.write(destination, bytes);
      if (valid()) {
        done = true;
        message = '文件已保存到你选择的位置。请按机构或家庭要求妥善保管。';
        selected = fresh;
      }
    } catch (e) {
      if (available) {
        error = e is PlatformException
            ? const ParentApiException(0, 'EXPORT_SAVE_FAILED')
            : e;
        if (e is ParentApiException && (e.status == 403 || e.status == 404)) {
          selected = null;
          page = null;
          retry = () => _open(job.id);
        }
      }
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
      if (!done) _abort();
      saving = false;
      if (mounted) setState(() => busy = false);
      if (available && selected == null && page == null && error == null) {
        _load(reset: true);
      }
    }
  }

  void _back() {
    poll?.cancel();
    setState(() => selected = null);
    if (page == null && !busy) _load(target: cursor);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: operation,
      builder: (context, _) => PopScope(
          canPop: !busy && !operation.busy && selected == null,
          onPopInvoked: (didPop) {
            if (!didPop && !busy && !operation.busy && selected != null) {
              _back();
            }
          },
          child: Scaffold(
            appBar: AppBar(
                title: Text(selected == null ? '我的操作记录导出' : '导出详情'),
                leading: selected == null
                    ? null
                    : IconButton(
                        tooltip: '返回导出列表',
                        onPressed: busy ? null : _back,
                        icon: const Icon(Icons.arrow_back)),
                actions: [
                  IconButton(
                      tooltip: '刷新导出',
                      onPressed: available && !busy && !operation.busy
                          ? () => selected == null
                              ? _load(reset: true)
                              : _open(selected!.id)
                          : null,
                      icon: const Icon(Icons.refresh))
                ]),
            body: !current
                ? const Center(child: Text('身份或工作空间已变化，请重新打开。'))
                : !foreground
                    ? const Center(child: Text('返回应用后继续核对。'))
                    : Column(children: [
                        ParentKnownOperationReceipt(operation: operation),
                        if (busy || operation.busy)
                          const LinearProgressIndicator(),
                        Expanded(
                            child: ListView(
                                padding: const EdgeInsets.all(16),
                                children: [
                              if (operation.resultTerminal != null)
                                ParentResultTerminalPanel(operation: operation,
                                    onViewCurrent: () => _load(reset: true),
                                    onEnded: () => _load(reset: true))
                              else if (operation.pending != null)
                                Card(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .secondaryContainer,
                                    child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const Text('上一次操作待核对',
                                                  style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold)),
                                              Text(operation.pending!['kind'] ==
                                                      'create'
                                                  ? '只查询原生成结果，不会自动重新生成。'
                                                  : '读取当前取消结果，不会自动重复取消。'),
                                              Wrap(spacing: 8, children: [
                                                OutlinedButton(
                                                    onPressed:
                                                        busy || operation.busy
                                                            ? null
                                                            : _recover,
                                                    child: const Text('查询原操作')),
                                                if (operation.queried)
                                                  TextButton(
                                                      onPressed:
                                                          busy || operation.busy
                                                              ? null
                                                              : _clear,
                                                      child: const Text('完成核对'))
                                              ]),
                                            ]))),
                              if (operation.resultTerminal == null && (error != null || operation.error != null))
                                Card(
                                    child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Text(_error(
                                            error ?? operation.error!)))),
                              if (message != null)
                                Card(
                                    child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Text(message!))),
                              if (selected != null)
                                ..._detail(selected!)
                              else ...[
                                Text('导出当前查询范围',
                                    style:
                                        Theme.of(context).textTheme.titleLarge),
                                const SizedBox(height: 8),
                                Text(selection(widget.query)),
                                const SizedBox(height: 12),
                                FilledButton.icon(
                                    onPressed: available &&
                                            !busy &&
                                            !operation.busy &&
                                            operation.loaded &&
                                            operation.pending == null
                                        ? _create
                                        : null,
                                    icon: const Icon(
                                        Icons.file_download_outlined),
                                    label: const Text('生成导出')),
                                if (!operation.loaded)
                                  TextButton(
                                      onPressed: operation.busy
                                          ? null
                                          : operation.load,
                                      child: const Text('重新读取恢复记录')),
                                const SizedBox(height: 20),
                                const Text('只有你本人创建的任务会出现在这里；生成中可离开，稍后返回下载。'),
                                if (!busy && page?.items.isEmpty == true)
                                  const Padding(
                                      padding:
                                          EdgeInsets.symmetric(vertical: 24),
                                      child: Text('暂无导出任务。')),
                                for (final job
                                    in page?.items ?? <AuditExportJob>[])
                                  Card(
                                      child: ListTile(
                                          title: Text(job.title),
                                          subtitle: Text(
                                              '${time(job.createdAt)}\n${job.description}'),
                                          trailing:
                                              const Icon(Icons.chevron_right),
                                          onTap: busy
                                              ? null
                                              : () => _open(job.id))),
                                if (page != null)
                                  Wrap(
                                      spacing: 12,
                                      alignment: WrapAlignment.spaceBetween,
                                      children: [
                                        OutlinedButton(
                                            onPressed:
                                                !busy && history.isNotEmpty
                                                    ? () => _load(
                                                        target: history.last,
                                                        direction: -1)
                                                    : null,
                                            child: const Text('上一页')),
                                        Text('第 ${history.length + 1} 页'),
                                        OutlinedButton(
                                            onPressed: !busy &&
                                                    page!.nextCursor != null
                                                ? () => _load(
                                                    target: page!.nextCursor,
                                                    direction: 1)
                                                : null,
                                            child: const Text('下一页'))
                                      ]),
                                if (error != null && retry != null)
                                  OutlinedButton(
                                      onPressed: busy ? null : retry,
                                      child: const Text('重试此次读取')),
                              ],
                            ]))
                      ]),
          )));
  List<Widget> _detail(AuditExportJob job) => [
        Card(
            margin: EdgeInsets.zero,
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(job.state == 'READY'
                          ? Icons.task_alt
                          : job.pending
                              ? Icons.hourglass_top
                              : Icons.info_outline),
                      const SizedBox(height: 12),
                      Text(job.title,
                          style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 8),
                      Text(job.description),
                      if (job.recordCount != null) ...[
                        const SizedBox(height: 12),
                        Text(
                            '${job.recordCount} 条记录 · ${((job.byteCount ?? 0) / 1024).toStringAsFixed(1)} KB',
                            style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ]))),
        const SizedBox(height: 16),
        Text('导出范围', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(selection(job.selection)),
        const SizedBox(height: 12),
        Text('有效至 ${time(job.expiresAt)}'),
        const SizedBox(height: 12),
        if (job.pending) const Text('当前页面每 5 秒查询一次；退出页面或进入后台会停止查询。'),
        if (job.state == 'READY') ...[
          const SizedBox(height: 20),
          FilledButton.icon(
              onPressed: busy || operation.busy || !widget.destination.supported
                  ? null
                  : () => _save(job),
              icon: const Icon(Icons.save_alt),
              label: const Text('选择位置并保存')),
          if (!widget.destination.supported)
            const Text('当前平台尚未接入文件保存，请使用已支持的 Android 手机或管理台。'),
        ],
        if (job.cancellable)
          TextButton(
              onPressed: busy || operation.busy || operation.pending != null
                  ? null
                  : () => _cancel(job),
              child: const Text('取消导出并清除在线文件')),
        ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('任务信息'),
            children: [
              Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                      '创建：${time(job.createdAt)}\n任务编号：${job.id}')),
            ]),
      ];
  String _error(Object e) =>
      e is ParentApiException && e.code == 'EXPORT_SAVE_FAILED'
          ? '文件未能完整保存。请检查保存位置；中止后会尝试清理未完成文件，部分提供方可能保留空文件。'
          : auditExportError(e);
}
