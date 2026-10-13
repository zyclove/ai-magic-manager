import 'package:flutter/material.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import '../core/paged_collection.dart';
import '../core/schedules.dart';
import 'schedule_editor.dart';

class ScheduleCenter extends StatefulWidget {
  final ParentSession session;
  final bool choosing;
  const ScheduleCenter(
      {super.key, required this.session, this.choosing = false});
  @override
  State<ScheduleCenter> createState() => _ScheduleCenterState();
}

class _ScheduleCenterState extends State<ScheduleCenter> {
  late final String tenant, actor, role;
  late final PagedCollection plans;
  bool navigating = false;
  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.tenant?['id'] == tenant &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;
  @override
  void initState() {
    super.initState();
    tenant = widget.session.tenant!['id'];
    actor = widget.session.profile!['subject'];
    role = widget.session.role;
    // A definition can contain 366 date overrides. Keep bounded responses small.
    plans = PagedCollection(widget.session.api, '/tenants/$tenant/schedules',
        pageSize: 5);
    widget.session.addListener(_scopeChanged);
  }

  void _scopeChanged() {
    if (!mounted || current) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    widget.session.removeListener(_scopeChanged);
    plans.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (!current || navigating || !widget.session.canDecide) return;
    setState(() => navigating = true);
    final created = await Navigator.of(context).push<Json>(MaterialPageRoute(
        builder: (_) => ScheduleEditorPage(session: widget.session)));
    if (!mounted || !current) return;
    setState(() => navigating = false);
    if (created != null) await _open(created['id']);
    if (current) plans.reload();
  }

  Future<void> _open(String id) async {
    if (!current || navigating) return;
    setState(() => navigating = true);
    final selected = await Navigator.of(context).push<Json>(MaterialPageRoute(
        builder: (_) => _ScheduleDetail(
            session: widget.session, id: id, choosing: widget.choosing)));
    if (current) {
      setState(() => navigating = false);
      if (widget.choosing && selected != null && mounted) {
        Navigator.pop(context, selected);
        return;
      }
      plans.reload();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('时间计划'), actions: [
        if (widget.session.canDecide)
          TextButton.icon(
              onPressed: navigating ? null : _create,
              icon: const Icon(Icons.add),
              label: const Text('新建 / 恢复')),
      ]),
      body: AnimatedBuilder(
          animation: plans,
          builder: (context, _) => RefreshIndicator(
              onRefresh: plans.reload,
              child: ListView(padding: const EdgeInsets.all(20), children: [
                const Text('按计划安排可用时间',
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                const Text('时间计划独立保存。需要在策略的“使用时段”规则中选择，预览并发布后才进入配置流程。'),
                if (!plans.loaded && plans.error == null || plans.loadingMore)
                  const LinearProgressIndicator(),
                if (plans.error != null) ...[
                  Text('${plans.error}'),
                  OutlinedButton(
                      onPressed: plans.reload, child: const Text('重新读取'))
                ],
                if (plans.loaded && plans.items.isEmpty)
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text('还没有时间计划，管理员可从右上角创建。')),
                for (final plan in plans.items)
                  Card(
                      child: ListTile(
                          title: Text(
                              plan['name'] is String ? plan['name'] : '未命名计划'),
                          subtitle: Text(plan['definition'] is Json
                              ? '${plan['definition']['timeZone'] ?? '时区未知'} · 查看每周安排与例外日期'
                              : '查看计划详情'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: navigating || plan['id'] is! String
                              ? null
                              : () => _open(plan['id']))),
                if (plans.hasMore)
                  TextButton(
                      onPressed: plans.loadingMore ? null : plans.loadMore,
                      child: const Text('加载更多计划')),
              ]))));
}

/// Reusable read-only details for both the schedule center and a rule form.
class ScheduleDefinitionView extends StatelessWidget {
  final Json definition;
  const ScheduleDefinitionView({super.key, required this.definition});
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('计划时区：${definition['timeZone']}',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const Text('结束时刻不包含；例外日期覆盖该日全部每周时段，并切断前一天延续的时段。'),
        ExpansionTile(
            initiallyExpanded: true,
            title: Text('每周时段 · ${(definition['weekly'] as List).length}'),
            children: [
              if ((definition['weekly'] as List).isEmpty)
                const ListTile(title: Text('无每周可用时段')),
              for (final row in definition['weekly'])
                ListTile(
                    title: Text(
                        '${scheduleDayNames[scheduleDays.indexOf(row['day'])]} ${scheduleWindowLabel(row)}')),
            ]),
        ExpansionTile(
            title: Text('例外日期 · ${(definition['exceptions'] as List).length}'),
            children: [
              if ((definition['exceptions'] as List).isEmpty)
                const ListTile(title: Text('无例外日期')),
              for (final row in definition['exceptions'])
                ListTile(
                    title: Text(row['date']),
                    subtitle: Text((row['windows'] as List).isEmpty
                        ? '当天全天不可用'
                        : (row['windows'] as List)
                            .map((w) => scheduleWindowLabel(w))
                            .join('、'))),
            ]),
      ]);
}

class _ScheduleDetail extends StatefulWidget {
  final ParentSession session;
  final String id;
  final bool choosing;
  const _ScheduleDetail(
      {required this.session, required this.id, this.choosing = false});
  @override
  State<_ScheduleDetail> createState() => _ScheduleDetailState();
}

class _ScheduleDetailState extends State<_ScheduleDetail> {
  late final String tenant, actor, role;
  late Future<Json> plan;
  Json? decision;
  DateTime? checkedAt;
  Object? error;
  bool busy = false;
  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.tenant?['id'] == tenant &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;
  @override
  void initState() {
    super.initState();
    tenant = widget.session.tenant!['id'];
    actor = widget.session.profile!['subject'];
    role = widget.session.role;
    widget.session.addListener(_scopeChanged);
    plan = _load();
  }

  Future<Json> _load() async {
    final result = readSchedule(await widget.session.api.object(
        '/tenants/$tenant/schedules/${widget.id}',
        isCurrent: () => current));
    if (result['id'] != widget.id) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return result;
  }

  void _scopeChanged() {
    if (!mounted || current) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    widget.session.removeListener(_scopeChanged);
    super.dispose();
  }

  Future<void> _evaluate(Json schedule) async {
    if (!current || busy) return;
    setState(() {
      busy = true;
      decision = null;
      error = null;
    });
    final instant = DateTime.now().toUtc();
    try {
      final result = await widget.session.api.object(
          '/tenants/$tenant/schedules/${widget.id}/evaluation?at=${Uri.encodeQueryComponent(instant.toIso8601String())}',
          isCurrent: () => current);
      validateScheduleDecision(
          result, schedule['definition']['timeZone'], instant);
      if (current) {
        setState(() {
          decision = result;
          checkedAt = instant;
        });
      }
    } catch (failure) {
      if (current) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _copy(Json schedule) async {
    if (!current || busy || !widget.session.canDecide) return;
    setState(() => busy = true);
    final result = await Navigator.of(context).push<Json>(MaterialPageRoute(
        builder: (_) =>
            ScheduleEditorPage(session: widget.session, seed: schedule)));
    if (!mounted || !current) return;
    setState(() => busy = false);
    if (result != null) {
      final selected = await Navigator.of(context).push<Json>(MaterialPageRoute(
          builder: (_) => _ScheduleDetail(
              session: widget.session,
              id: result['id'],
              choosing: widget.choosing)));
      if (mounted && current && widget.choosing && selected != null) {
        Navigator.pop(context, selected);
      }
    }
  }

  String localTime(dynamic value) => value is String
      ? DateTime.parse(value).toLocal().toString().split('.').first
      : '—';
  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: Scaffold(
          appBar: AppBar(title: const Text('时间计划详情')),
          body: FutureBuilder<Json>(
              future: plan,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('${snapshot.error}'),
                    OutlinedButton(
                        onPressed: () => setState(() => plan = _load()),
                        child: const Text('重试'))
                  ]));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final schedule = snapshot.data!;
                return ListView(padding: const EdgeInsets.all(20), children: [
                  Text(schedule['name'],
                      style: const TextStyle(
                          fontSize: 24, fontWeight: FontWeight.w700)),
                  ScheduleDefinitionView(definition: schedule['definition']),
                  if (widget.choosing && widget.session.canDecide)
                    FilledButton.icon(
                        onPressed: busy
                            ? null
                            : () => Navigator.pop(context, schedule),
                        icon: const Icon(Icons.check),
                        label: const Text('用于当前规则')),
                  if (widget.session.canDecide)
                    OutlinedButton.icon(
                        onPressed: busy ? null : () => _copy(schedule),
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('复制并调整为新计划')),
                  const Text('计划不可原地覆盖；复制后的计划需重新绑定策略规则。'),
                  FilledButton.icon(
                      onPressed: busy ? null : () => _evaluate(schedule),
                      icon: const Icon(Icons.schedule),
                      label: const Text('检查此刻的计划安排')),
                  if (busy) const LinearProgressIndicator(),
                  if (error != null)
                    Text('$error',
                        style: const TextStyle(color: Color(0xFF9A3931))),
                  if (decision != null)
                    Card(
                        child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      decision!['allowed'] == true
                                          ? '计划内：此刻可用'
                                          : '计划内：此刻不可用',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge),
                                  Text(
                                      '计划时区 ${decision!['timeZone']} · 当地日期 ${decision!['localDate']}'),
                                  Text(
                                      '检查时刻（手机时间）：${checkedAt!.toLocal().toString().split('.').first}'),
                                  if (decision!['currentUntil'] != null)
                                    Text(
                                        '当前时段结束（手机时间）：${localTime(decision!['currentUntil'])}'),
                                  if (decision!['nextAllowedAt'] != null)
                                    Text(
                                        '下一可用时段（手机时间）：${localTime(decision!['nextAllowedAt'])}'),
                                  if (decision!['reasonCode'] ==
                                      'NO_WINDOW_IN_PREVIEW_HORIZON')
                                    const Text(
                                        '未来 8 个计划日内未找到可用时段，不代表更远日期永远不可用。'),
                                  const Text(
                                      '这是时间计划的静态检查，不代表设备正在执行，也未合并其他应用、额度或安全规则。'),
                                ]))),
                ]);
              })));
}
