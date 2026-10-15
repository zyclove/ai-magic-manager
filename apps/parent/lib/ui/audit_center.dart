import 'package:flutter/material.dart';
import '../core/audit.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';

/// Mobile audit investigation with bounded pages and explicit, applied filters.
/// No event payload is persisted locally or treated as device execution proof.
class AuditCenter extends StatefulWidget {
  final ParentSession session;
  const AuditCenter({super.key, required this.session});
  @override
  State<AuditCenter> createState() => _AuditCenterState();
}

class _AuditCenterState extends State<AuditCenter> with WidgetsBindingObserver {
  late final String? tenant, actor, role;
  late final int generation;
  late final ParentAuditRepository repository;
  late AuditQuery query;
  AuditPage? page;
  AuditEvent? selected;
  String? cursor;
  final history = <String?>[];
  Object? error;
  VoidCallback? retry;
  bool foreground = true, busy = false;
  int epoch = 0;
  int? recentDays = 7;
  Route<dynamic>? overlay;
  ParentSession get session => widget.session;
  bool get current =>
      mounted &&
      session.authenticated &&
      tenant != null &&
      session.tenant?['id'] == tenant &&
      session.profile?['subject'] == actor &&
      session.role == role &&
      session.generation == generation &&
      auditRoles.contains(role);
  bool get available => current && foreground;

  @override
  void initState() {
    super.initState();
    tenant = session.tenant?['id'];
    actor = session.profile?['subject'];
    role = session.role;
    generation = session.generation;
    repository = ParentAuditRepository(
        api: session.api, tenant: tenant ?? '', current: () => available);
    query = _recent(7);
    session.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    if (available) _load();
  }

  AuditQuery _recent(int days) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return AuditQuery(from: now - days * 86400000, to: now);
  }

  void _closeOverlay() {
    if (overlay?.isActive == true) overlay!.navigator?.removeRoute(overlay!);
    overlay = null;
  }

  void _changed() {
    if (current) return;
    epoch++;
    page = null;
    selected = null;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      _closeOverlay();
      final route = ModalRoute.of(context);
      if (route?.isActive == true && route?.isFirst == false) {
        route!.navigator?.removeRoute(route);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (foreground == resumed) return;
    foreground = resumed;
    epoch++;
    _closeOverlay();
    page = null;
    selected = null;
    error = null;
    retry = null;
    busy = false;
    if (mounted) setState(() {});
    if (available) _refresh();
  }

  @override
  void dispose() {
    epoch++;
    session.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _refresh() {
    if (!available) return;
    if (recentDays != null) {
      final range = _recent(recentDays!);
      query = AuditQuery(
          from: range.from,
          to: range.to,
          action: query.action,
          resourceId: query.resourceId,
          correlationId: query.correlationId);
    }
    history.clear();
    cursor = null;
    selected = null;
    _load();
  }

  Future<void> _load(
      {String? target, int direction = 0, AuditEvent? boundary}) async {
    if (!available) return;
    final ticket = ++epoch;
    final applied = query;
    // Preserve the exact failed page and its direction for explicit retry.
    setState(() {
      busy = true;
      page = null;
      error = null;
      retry = null;
    });
    try {
      final result = await repository.load(applied, cursor: target);
      if (!available || ticket != epoch) return;
      if (direction > 0 &&
          result.nextCursor != null &&
          history.contains(result.nextCursor)) {
        throw const ParentApiException(502, 'INVALID_AUDIT_RESPONSE');
      }
      if (boundary != null && result.items.isNotEmpty) {
        final first = result.items.first;
        if (first.occurredAt > boundary.occurredAt ||
            (first.occurredAt == boundary.occurredAt &&
                first.id.compareTo(boundary.id) >= 0)) {
          throw const ParentApiException(502, 'INVALID_AUDIT_RESPONSE');
        }
      }
      setState(() {
        if (direction > 0) history.add(cursor);
        if (direction < 0 && history.isNotEmpty) history.removeLast();
        cursor = target;
        page = result;
      });
    } catch (failure) {
      if (available && ticket == epoch) {
        setState(() {
          error = failure;
          retry = () =>
              _load(target: target, direction: direction, boundary: boundary);
        });
      }
    } finally {
      if (available && ticket == epoch) setState(() => busy = false);
    }
  }

  Future<void> _open(String id) async {
    if (!available || busy) return;
    final ticket = ++epoch;
    setState(() {
      busy = true;
      error = null;
      retry = null;
    });
    try {
      final item = await repository.detail(id);
      if (available && ticket == epoch) setState(() => selected = item);
    } catch (failure) {
      if (available && ticket == epoch) {
        setState(() {
          // An authorization failure must also remove the previously visible page.
          page = null;
          error = failure;
          retry = () => _open(id);
        });
      }
    } finally {
      if (available && ticket == epoch) setState(() => busy = false);
    }
  }

  Future<void> _filters() async {
    if (!available || busy) return;
    final route = DialogRoute<AuditQuery>(
        context: context, builder: (_) => _AuditFilters(query: query));
    overlay = route;
    final value = await Navigator.of(context).push(route);
    if (identical(overlay, route)) overlay = null;
    if (!available || value == null) return;
    recentDays = null;
    query = value;
    _refresh();
  }

  String time(int value) {
    final d = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  void _related({String? resource, String? trace}) {
    query = AuditQuery(
        from: query.from,
        to: query.to,
        resourceId: resource,
        correlationId: trace);
    recentDays = null;
    _refresh();
  }

  Widget _field(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        SelectableText(value),
      ]));

  void _backToList() {
    setState(() => selected = null);
    // A failed detail read clears the old list. If retry succeeds, returning
    // must reload that page rather than leave the user with an empty surface.
    if (page == null && available && !busy) _load(target: cursor);
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: selected == null,
      onPopInvoked: (didPop) {
        if (!didPop && selected != null) _backToList();
      },
      child: Scaffold(
        appBar: AppBar(
            title: Text(selected == null ? '操作记录' : '记录详情'),
            leading: selected == null
                ? null
                : IconButton(
                    tooltip: '返回记录列表',
                    onPressed: _backToList,
                    icon: const Icon(Icons.arrow_back)),
            actions: [
              IconButton(
                  tooltip: '刷新操作记录',
                  onPressed: available && !busy ? _refresh : null,
                  icon: const Icon(Icons.refresh))
            ]),
        body: !current
            ? const Center(child: Text('当前身份没有操作记录查看权限。'))
            : !foreground
                ? const Center(child: Text('返回应用后重新读取操作记录。'))
                : Column(children: [
                    if (busy) const LinearProgressIndicator(),
                    Expanded(
                        child: selected != null ? _detail(selected!) : _list()),
                  ]),
        bottomNavigationBar: available && selected == null && page != null
            ? SafeArea(
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          OutlinedButton(
                              onPressed: !busy && history.isNotEmpty
                                  ? () =>
                                      _load(target: history.last, direction: -1)
                                  : null,
                              child: const Text('上一页')),
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                  '第 ${history.length + 1} 页 · ${page!.items.length} 条')),
                          FilledButton(
                              onPressed: !busy && page!.nextCursor != null
                                  ? () => _load(
                                      target: page!.nextCursor,
                                      direction: 1,
                                      boundary: page!.items.last)
                                  : null,
                              child: const Text('下一页')),
                        ])))
            : null,
      ));

  Widget _list() => ListView(children: [
        Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${session.tenant?['name'] ?? '当前工作空间'} · 管理操作',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text('记录服务端已登记的操作。配置、审批与设备实际执行请分别核对。'),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final days in [1, 7, 30])
                  ChoiceChip(
                      label: Text('最近 $days 天'),
                      selected: recentDays == days,
                      onSelected: busy
                          ? null
                          : (_) {
                              recentDays = days;
                              query = _recent(days);
                              _refresh();
                            }),
                ActionChip(
                    label: const Text('筛选记录'),
                    avatar: const Icon(Icons.filter_list, size: 18),
                    onPressed: busy ? null : _filters),
              ]),
              const SizedBox(height: 8),
              Text(
                  '查询范围：${time(query.from)} 至 ${time(query.to)}（不含结束时刻）\n本机时区 ${DateTime.now().timeZoneName}；最新在前。',
                  style: Theme.of(context).textTheme.bodySmall),
              if (query.action != null)
                Text('操作：${auditActionName(query.action!)}'),
              if (query.resourceId != null) Text('对象：${query.resourceId}'),
              if (query.correlationId != null)
                Text('关联请求：${query.correlationId}'),
              if (error != null)
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(auditError(error!)),
                              const SizedBox(height: 8),
                              OutlinedButton(
                                  onPressed: busy ? null : retry,
                                  child: const Text('重试此次读取')),
                            ]))),
              if (!busy && error == null && page?.items.isEmpty == true)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text('这段时间没有符合条件的操作记录。可扩大时间范围或调整筛选。')),
            ])),
        for (final item in page?.items ?? <AuditEvent>[])
          Card(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                title: Text(auditActionName(item.action)),
                subtitle:
                    Text('${time(item.occurredAt)}\n操作者标识：${item.actorId}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: busy ? null : () => _open(item.id),
              )),
      ]);

  Widget _detail(AuditEvent item) =>
      ListView(padding: const EdgeInsets.all(20), children: [
        Text(auditActionName(item.action),
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('服务端操作记录；不单独证明设备已执行规则。'),
        _field(
            '发生时间（本机时区 ${DateTime.now().timeZoneName}）', time(item.occurredAt)),
        _field('操作者标识', item.actorId),
        _field('操作代码', item.action),
        _field('操作对象编号', item.resourceId),
        _field('关联请求编号', item.correlationId),
        _field('事件编号', item.id),
        const SizedBox(height: 12),
        if (auditResourceId(item.resourceId))
          OutlinedButton.icon(
              onPressed: () => _related(resource: item.resourceId),
              icon: const Icon(Icons.history),
              label: const Text('查看同一对象的记录')),
        if (auditUuid.hasMatch(item.correlationId))
          OutlinedButton.icon(
              onPressed: () => _related(trace: item.correlationId),
              icon: const Icon(Icons.link),
              label: const Text('查看同一请求的记录')),
        const Text('关联查询沿用当前时间范围。详情文字可长按选择复制。'),
      ]);
}

class _AuditFilters extends StatefulWidget {
  final AuditQuery query;
  const _AuditFilters({required this.query});
  @override
  State<_AuditFilters> createState() => _AuditFiltersState();
}

class _AuditFiltersState extends State<_AuditFilters> {
  final form = GlobalKey<FormState>();
  late final TextEditingController action, resource, trace, start, end;
  TextEditingController? choosing;
  @override
  void initState() {
    super.initState();
    action = TextEditingController(text: widget.query.action);
    resource = TextEditingController(text: widget.query.resourceId);
    trace = TextEditingController(text: widget.query.correlationId);
    String date(int value) {
      final d = DateTime.fromMillisecondsSinceEpoch(value);
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }

    start = TextEditingController(text: date(widget.query.from));
    end = TextEditingController(text: date(widget.query.to - 1));
  }

  DateTime? day(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return null;
    final d = DateTime.tryParse(value);
    if (d == null ||
        d.year < 1970 ||
        d.year > 9998 ||
        d.toIso8601String().substring(0, 10) != value) return null;
    return d;
  }

  @override
  void dispose() {
    for (final c in [action, resource, trace, start, end]) {
      c.dispose();
    }
    super.dispose();
  }

  String? optional(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();
  void apply() {
    if (!form.currentState!.validate()) return;
    final first = day(start.text.trim())!, last = day(end.text.trim())!;
    final until = DateTime(last.year, last.month, last.day + 1);
    Navigator.pop(
        context,
        AuditQuery(
            from: first.millisecondsSinceEpoch,
            to: until.millisecondsSinceEpoch,
            action: optional(action),
            resourceId: optional(resource),
            correlationId: optional(trace)));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('筛选操作记录'),
          content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                  child: Form(
                      key: form,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Text(
                            '按本机日期查询，包含开始日和结束日；一次最多 366 天。留空高级条件可查看全部操作。'),
                        TextFormField(
                            controller: start,
                            decoration: InputDecoration(
                                labelText: '开始日期',
                                hintText: 'YYYY-MM-DD',
                                suffixIcon: IconButton(
                                    tooltip: '选择开始日期',
                                    icon: const Icon(Icons.calendar_month),
                                    onPressed: () =>
                                        setState(() => choosing = start))),
                            validator: (s) => day(s!.trim()) == null
                                ? '请输入有效日期，如 2026-10-15'
                                : null),
                        TextFormField(
                            controller: end,
                            decoration: InputDecoration(
                                labelText: '结束日期',
                                hintText: 'YYYY-MM-DD',
                                suffixIcon: IconButton(
                                    tooltip: '选择结束日期',
                                    icon: const Icon(Icons.calendar_month),
                                    onPressed: () =>
                                        setState(() => choosing = end))),
                            validator: (s) {
                              final a = day(start.text.trim()),
                                  b = day(s!.trim());
                              if (b == null) return '请输入有效日期，如 2026-10-15';
                              if (a != null &&
                                  (b.isBefore(a) ||
                                      DateTime(b.year, b.month, b.day + 1)
                                              .difference(a) >
                                          const Duration(days: 366))) {
                                return '结束日不能早于开始日，范围最多 366 天';
                              }
                              return null;
                            }),
                        if (choosing != null)
                          CalendarDatePicker(
                              key: ValueKey(choosing),
                              initialDate:
                                  day(choosing!.text.trim()) ?? DateTime.now(),
                              firstDate: DateTime(1970),
                              lastDate: DateTime(9998, 12, 31),
                              onDateChanged: (value) => setState(() {
                                    choosing!.text =
                                        '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
                                    choosing = null;
                                  })),
                        const SizedBox(height: 16),
                        TextFormField(
                            controller: action,
                            maxLength: 100,
                            decoration: const InputDecoration(
                                labelText: '操作代码（选填）', hintText: '可从记录详情复制'),
                            validator: (s) => s!.trim().isEmpty ||
                                    RegExp(r'^[A-Z][A-Z0-9_]{0,99}$')
                                        .hasMatch(s.trim())
                                ? null
                                : '请输入大写操作代码'),
                        TextFormField(
                            controller: resource,
                            maxLength: 64,
                            decoration:
                                const InputDecoration(labelText: '操作对象编号（选填）'),
                            validator: (s) =>
                                s!.trim().isEmpty || auditResourceId(s.trim())
                                    ? null
                                    : '请复制完整的对象编号'),
                        TextFormField(
                            controller: trace,
                            maxLength: 36,
                            decoration:
                                const InputDecoration(labelText: '关联请求编号（选填）'),
                            validator: (s) => s!.trim().isEmpty ||
                                    auditUuid.hasMatch(s.trim())
                                ? null
                                : '请复制完整的小写 UUID 编号'),
                      ])))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(onPressed: apply, child: const Text('应用筛选'))
          ]);
}
