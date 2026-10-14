import 'dart:convert';
import 'package:flutter/material.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import '../core/schedules.dart';
import '../core/schedule_presets.dart';

class ScheduleEditorPage extends StatefulWidget {
  final ParentSession session;
  final Json? seed;
  final ScheduleCreationStore? store;
  const ScheduleEditorPage(
      {super.key, required this.session, this.seed, this.store});
  @override
  State<ScheduleEditorPage> createState() => _ScheduleEditorPageState();
}

class _ScheduleEditorPageState extends State<ScheduleEditorPage> {
  late final String tenant, actor, role;
  late final int generation;
  late final ScheduleCreationController controller;
  final name = TextEditingController(), zone = TextEditingController();
  final form = GlobalKey<FormState>();
  List<Json> weekly = [], exceptions = [];
  bool dirty = false, allowExit = false;
  Object? editError;
  bool loadingPresets = false, choosingPresets = false;
  String? presetNotice;
  Route<dynamic>? presetRoute;
  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.canDecide &&
      widget.session.generation == generation &&
      widget.session.tenant?['id'] == tenant &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;
  @override
  void initState() {
    super.initState();
    tenant = widget.session.tenant!['id'];
    actor = widget.session.profile!['subject'];
    role = widget.session.role;
    generation = widget.session.generation;
    zone.text =
        widget.session.tenant?['timeZone'] as String? ?? 'Asia/Shanghai';
    if (widget.seed != null) {
      final seed = jsonDecode(jsonEncode(readSchedule(widget.seed))) as Json;
      name.text = seed['name'];
      zone.text = seed['definition']['timeZone'];
      weekly = (seed['definition']['weekly'] as List).cast<Json>();
      exceptions = (seed['definition']['exceptions'] as List).cast<Json>();
    }
    controller = ScheduleCreationController(
        api: widget.session.api,
        store: widget.store ?? ScheduleCreationStore(),
        tenant: tenant,
        actor: actor,
        isCurrent: () => current && !widget.session.busy);
    widget.session.addListener(_scopeChanged);
    controller.load();
  }

  void _scopeChanged() {
    if (!mounted || current) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      final dialog = presetRoute;
      if (dialog != null && dialog.isActive) {
        dialog.navigator?.removeRoute(dialog);
      }
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
    // A settled dialog has no animation to schedule the frame needed above.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    widget.session.removeListener(_scopeChanged);
    controller.dispose();
    name.dispose();
    zone.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    if (controller.busy) return;
    if (dirty && controller.pending == null) {
      final discard = await showDialog<bool>(
          context: context,
          builder: (ctx) =>
              AlertDialog(title: const Text('放弃尚未保存的计划？'), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('继续编辑')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('放弃'))
              ]));
      if (!current || discard != true) return;
    }
    if (!mounted) return;
    setState(() => allowExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  // Own these routes so a workspace change also closes a pending picker/confirmation.
  Future<T?> _presetDialog<T>(WidgetBuilder builder) async {
    final route = DialogRoute<T>(context: context, builder: builder);
    presetRoute = route;
    try {
      return await Navigator.of(context).push(route);
    } finally {
      if (identical(presetRoute, route)) presetRoute = null;
    }
  }

  Future<void> _choosePreset() async {
    if (!current || controller.busy || choosingPresets) return;
    setState(() {
      choosingPresets = true;
      loadingPresets = true;
      presetNotice = null;
    });
    try {
      final response = await widget.session.api.send(
          'GET', '/tenants/${Uri.encodeComponent(tenant)}/schedule-presets',
          isCurrent: () => current, maxResponseBytes: 65536);
      if (!current) return;
      final presets = SchedulePreset.readCatalog(response);
      setState(() => loadingPresets = false);
      if (presets.isEmpty) {
        setState(() => presetNotice = '暂未提供时间安排示例，可以在下方自行设置。');
        return;
      }
      final selected = await _presetDialog<SchedulePreset>((ctx) => AlertDialog(
              title: const Text('选择时间安排示例'),
              content: SizedBox(
                  width: 520,
                  child: SingleChildScrollView(
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                        const Text('选择后填入草稿，可继续调整。示例不代表适合孩子的建议时长。'),
                        const SizedBox(height: 12),
                        for (final preset in presets)
                          Card(
                              child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Text(preset.name,
                                            style: Theme.of(ctx)
                                                .textTheme
                                                .titleMedium),
                                        const SizedBox(height: 8),
                                        Text(preset.description),
                                        const SizedBox(height: 8),
                                        for (final day in scheduleDays)
                                          if (preset.weekly
                                              .any((row) => row['day'] == day))
                                            Text(
                                                '${scheduleDayNames[scheduleDays.indexOf(day)]}  '
                                                '${preset.weekly.where((row) => row['day'] == day).map(scheduleWindowLabel).join('、')}'),
                                        const SizedBox(height: 12),
                                        OutlinedButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, preset),
                                            child: Text('使用${preset.name}')),
                                      ]))),
                      ]))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('自行设置'))
              ]));
      if (!current || selected == null) return;
      if (weekly.isNotEmpty) {
        final confirmed = await _presetDialog<bool>((ctx) => AlertDialog(
                title: const Text('替换当前每周时段？'),
                content: Text(
                    '将使用“${selected.name}”替换当前 ${weekly.length} 条每周时段。计划名称、时区和 ${exceptions.length} 个例外日期会保留。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('保留原安排')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('替换每周时段')),
                ]));
        if (!current || confirmed != true) return;
      }
      setState(() {
        weekly = selected.weekly
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
        if (name.text.trim().isEmpty) name.text = selected.name;
        dirty = true;
        editError = null;
        presetNotice = '示例已填入，尚未保存。请检查下方安排后再保存。';
      });
    } catch (_) {
      if (current) setState(() => presetNotice = '暂时无法读取示例。可以重新选择，或在下方自行设置。');
    } finally {
      if (mounted) {
        setState(() {
          loadingPresets = false;
          choosingPresets = false;
        });
      }
    }
  }

  Future<void> _date([Json? original]) async {
    final date = original == null
        ? await showDatePicker(
            context: context,
            initialDate: DateTime.now(),
            firstDate: DateTime(1900),
            lastDate: DateTime(2200, 12, 31))
        : DateTime.parse(original['date']);
    if (!mounted || !current || date == null) return;
    final key =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final existing = exceptions.where((e) => e['date'] == key).firstOrNull;
    final rows = await Navigator.of(context).push<List<Json>>(MaterialPageRoute(
        builder: (_) => _DateWindowsPage(
            date: key,
            initial: (existing?['windows'] as List? ?? []).cast<Json>(),
            isCurrent: () => current,
            changes: widget.session)));
    if (!current || rows == null) return;
    setState(() {
      exceptions.removeWhere((e) => e['date'] == key);
      exceptions.add({'date': key, 'windows': rows});
      exceptions.sort((a, b) => (a['date'] as String).compareTo(b['date']));
      dirty = true;
    });
  }

  Future<void> _save() async {
    if (!current || choosingPresets || !form.currentState!.validate()) return;
    final definition = <String, dynamic>{
      'timeZone': zone.text.trim(),
      'weekly': weekly,
      'exceptions': exceptions
    };
    try {
      validateScheduleDefinition(definition);
    } catch (failure) {
      setState(() => editError = failure);
      return;
    }
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('保存独立时间计划？'),
                content: Text(
                    '每周 ${weekly.length} 条时段、${exceptions.length} 个例外日期。'
                    '${weekly.isEmpty && exceptions.every((e) => (e['windows'] as List).isEmpty) ? '当前没有任何可用时段。' : ''}'
                    '保存不会改变设备设置；还需要在策略规则中选择本计划。已有计划不会被覆盖。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('返回检查')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('确认保存'))
                ]));
    if (confirmed == true && current) {
      await controller.create(name.text, definition);
    }
  }

  Future<void> _acknowledge() async {
    final result = controller.result;
    if (result == null) {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: const Text('已核对原创建结果？'),
                  content:
                      const Text('查询不到不能证明未创建。请先在计划列表和管理台审计中核对。这里只清除本机提醒。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('返回')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('已核对，清除'))
                  ]));
      if (confirmed != true || !current) return;
    }
    if (await controller.acknowledge() && current) {
      if (result != null) {
        setState(() => allowExit = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (current) Navigator.pop(context, result);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => PopScope(
          canPop: allowExit ||
              !controller.busy && (!dirty || controller.pending != null),
          onPopInvoked: (didPop) {
            if (!didPop) _leave();
          },
          child: Scaffold(
            appBar: AppBar(
                title: const Text('创建时间计划'),
                leading: IconButton(
                    tooltip: '返回',
                    onPressed: controller.busy ? null : _leave,
                    icon: const Icon(Icons.arrow_back))),
            body: ListView(padding: const EdgeInsets.all(20), children: [
              const Text('按日历安排可用时间',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text('开始时间包含在内，结束时间不包含。结束早于开始表示延续到次日；同一天的多个时段取并集。'),
              if (controller.busy) const LinearProgressIndicator(),
              if (controller.error != null)
                Text('${controller.error}',
                    style: const TextStyle(color: Color(0xFF9A3931))),
              if (!controller.loaded && !controller.busy)
                OutlinedButton(
                    onPressed: controller.load, child: const Text('重新读取恢复记录')),
              if (controller.pending != null) ...[
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  controller.result == null
                                      ? '请先核对原创建'
                                      : '时间计划已保存',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              Text(
                                  '原名称：${controller.pending!['body']['name']}'),
                              Text(
                                  '原时区：${controller.pending!['body']['definition']['timeZone']}'),
                              SelectableText(
                                  '请求编号：${controller.pending!['requestId']}'),
                              if (controller.queried &&
                                  controller.result == null)
                                const Text('没有可读取的原结果，请核对计划列表及管理台审计。'),
                            ]))),
                OutlinedButton(
                    onPressed: controller.busy ? null : controller.query,
                    child: const Text('查询原创建结果')),
                if (controller.queried)
                  FilledButton(
                      onPressed: controller.busy ? null : _acknowledge,
                      child: Text(
                          controller.result == null ? '已核对，清除本机提醒' : '打开时间计划')),
              ] else if (controller.loaded)
                AbsorbPointer(
                    absorbing: controller.busy || choosingPresets,
                    child: Form(
                        key: form,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Card(
                                  child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            Text('先选安排，再做微调',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleMedium),
                                            const SizedBox(height: 8),
                                            const Text(
                                                '可以用示例快速填写，也可以直接在下方设置自己的时间。'),
                                            const SizedBox(height: 12),
                                            OutlinedButton.icon(
                                                onPressed: choosingPresets
                                                    ? null
                                                    : _choosePreset,
                                                icon: const Icon(Icons
                                                    .auto_awesome_outlined),
                                                label: Text(loadingPresets
                                                    ? '正在读取示例…'
                                                    : '选择时间安排示例')),
                                            if (loadingPresets)
                                              const LinearProgressIndicator(),
                                            if (presetNotice != null)
                                              Semantics(
                                                  liveRegion: true,
                                                  child: Text(presetNotice!)),
                                          ]))),
                              const SizedBox(height: 20),
                              TextFormField(
                                  controller: name,
                                  maxLength: 100,
                                  enabled: !controller.busy,
                                  decoration: const InputDecoration(
                                      labelText: '计划名称',
                                      border: OutlineInputBorder()),
                                  validator: (v) => v == null ||
                                          v.trim().isEmpty ||
                                          v.trim().length > 100
                                      ? '请输入 1–100 字符的名称'
                                      : null,
                                  onChanged: (_) =>
                                      setState(() => dirty = true)),
                              TextFormField(
                                  controller: zone,
                                  maxLength: 100,
                                  enabled: !controller.busy,
                                  decoration: const InputDecoration(
                                      labelText: '计划时区',
                                      helperText:
                                          '中国大陆通常为 Asia/Shanghai；不会随手机时区改变',
                                      border: OutlineInputBorder()),
                                  validator: (v) => v == null ||
                                          v.trim().isEmpty ||
                                          v.trim().length > 100
                                      ? '请填写有效的 IANA 时区'
                                      : null,
                                  onChanged: (_) =>
                                      setState(() => dirty = true)),
                              const SizedBox(height: 16),
                              if (weekly.isNotEmpty)
                                _WeeklyOverview(
                                    weekly: weekly,
                                    onRemove: (row) {
                                      if (!current) return;
                                      setState(() {
                                        weekly.remove(row);
                                        dirty = true;
                                      });
                                    }),
                              Text('每周时段 · ${weekly.length}/56',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              ScheduleWindowComposer(
                                  weekly: true,
                                  remaining: 56 - weekly.length,
                                  onAdd: (rows) {
                                    if (current) {
                                      setState(() {
                                        weekly.addAll(rows.where((row) =>
                                            !weekly.any((existing) =>
                                                existing['day'] == row['day'] &&
                                                existing['start'] ==
                                                    row['start'] &&
                                                existing['end'] ==
                                                    row['end'])));
                                        dirty = true;
                                      });
                                    }
                                  }),
                              const SizedBox(height: 16),
                              Text('例外日期 · ${exceptions.length}/366',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              const Text(
                                  '例外日期覆盖当天全部每周安排，也会切断前一天跨午夜延续的时段。空时段表示当天全天不可用。'),
                              OutlinedButton.icon(
                                  onPressed: exceptions.length >= 366
                                      ? null
                                      : () => _date(),
                                  icon: const Icon(Icons.event),
                                  label: const Text('添加例外日期')),
                              for (int i = 0; i < exceptions.length; i++)
                                ListTile(
                                    title: Text(exceptions[i]['date']),
                                    subtitle: Text((exceptions[i]['windows']
                                                as List)
                                            .isEmpty
                                        ? '当天全天不可用'
                                        : '${(exceptions[i]['windows'] as List).length} 条替代时段'),
                                    onTap: () => _date(exceptions[i]),
                                    trailing: IconButton(
                                        tooltip:
                                            '移除例外 ${exceptions[i]['date']}',
                                        onPressed: () => setState(() {
                                              exceptions.removeAt(i);
                                              dirty = true;
                                            }),
                                        icon:
                                            const Icon(Icons.delete_outline))),
                              if (editError != null) Text('$editError'),
                              const SizedBox(height: 20),
                              FilledButton(
                                  onPressed: controller.busy ? null : _save,
                                  child: const Text('保存独立时间计划')),
                            ]))),
            ]),
          )));
}

/// Text-backed overview stays readable with screen readers and large font sizes.
class _WeeklyOverview extends StatelessWidget {
  final List<Json> weekly;
  final ValueChanged<Json> onRemove;
  const _WeeklyOverview({required this.weekly, required this.onRemove});
  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('一周安排预览', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('按时段开始的星期展示；例外日期会覆盖当天安排。'),
            const SizedBox(height: 8),
            for (var i = 0; i < scheduleDays.length; i++)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(scheduleDayNames[i],
                            style: Theme.of(context).textTheme.labelLarge),
                        if (!weekly.any((row) => row['day'] == scheduleDays[i]))
                          const Text('无新开始时段'),
                        for (final row in weekly
                            .where((row) => row['day'] == scheduleDays[i]))
                          InputChip(
                              label: Text(scheduleWindowLabel(row)),
                              deleteButtonTooltipMessage:
                                  '移除${scheduleDayNames[i]} ${scheduleWindowLabel(row)}',
                              onDeleted: () => onRemove(row)),
                      ])),
          ])));
}

/// Flutter owns accessible clock input; these are wall times, not UTC instants.
class ScheduleWindowComposer extends StatefulWidget {
  final bool weekly;
  final int remaining;
  final ValueChanged<List<Json>> onAdd;
  const ScheduleWindowComposer(
      {super.key,
      required this.weekly,
      required this.remaining,
      required this.onAdd});
  @override
  State<ScheduleWindowComposer> createState() => _ScheduleWindowComposerState();
}

class _ScheduleWindowComposerState extends State<ScheduleWindowComposer> {
  final days = <String>{'MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY'};
  TimeOfDay start = const TimeOfDay(hour: 18, minute: 0),
      end = const TimeOfDay(hour: 20, minute: 0);
  String? error;
  String text(TimeOfDay value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  Future<void> pick(bool first) async {
    final value = await showTimePicker(
        context: context,
        initialTime: first ? start : end,
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
            child: child!));
    if (mounted && value != null) {
      setState(() {
        if (first) {
          start = value;
        } else {
          end = value;
        }
      });
    }
  }

  void add() {
    final count = widget.weekly ? days.length : 1;
    if (text(start) == text(end) || count == 0 || count > widget.remaining) {
      setState(() => error = '请检查星期和起止时间，并确认未超过时段数量上限。');
      return;
    }
    widget.onAdd([
      for (final day in widget.weekly ? days : [''])
        {if (widget.weekly) 'day': day, 'start': text(start), 'end': text(end)}
    ]);
    setState(() => error = null);
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (widget.weekly)
          Wrap(spacing: 6, children: [
            for (int i = 0; i < 7; i++)
              FilterChip(
                  label: Text(scheduleDayNames[i]),
                  selected: days.contains(scheduleDays[i]),
                  onSelected: (v) => setState(() {
                        if (v) {
                          days.add(scheduleDays[i]);
                        } else {
                          days.remove(scheduleDays[i]);
                        }
                      }))
          ]),
        Wrap(spacing: 12, children: [
          OutlinedButton(
              onPressed: () => pick(true), child: Text('开始 ${text(start)}')),
          OutlinedButton(
              onPressed: () => pick(false), child: Text('结束 ${text(end)}'))
        ]),
        if (text(end).compareTo(text(start)) < 0) const Text('此时段延续到次日。'),
        if (error != null)
          Text(error!, style: const TextStyle(color: Color(0xFF9A3931))),
        TextButton.icon(
            onPressed: widget.remaining <= 0 ? null : add,
            icon: const Icon(Icons.add),
            label: const Text('添加时段')),
      ]);
}

class _DateWindowsPage extends StatefulWidget {
  final String date;
  final List<Json> initial;
  final bool Function() isCurrent;
  final Listenable changes;
  const _DateWindowsPage(
      {required this.date,
      required this.initial,
      required this.isCurrent,
      required this.changes});
  @override
  State<_DateWindowsPage> createState() => _DateWindowsPageState();
}

class _DateWindowsPageState extends State<_DateWindowsPage> {
  late final rows =
      widget.initial.map((e) => Map<String, dynamic>.from(e)).toList();
  bool dirty = false, allowExit = false;
  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_close);
  }

  void _close() {
    if (!mounted || widget.isCurrent()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.isCurrent()) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    widget.changes.removeListener(_close);
    super.dispose();
  }

  Future<void> _leave() async {
    final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(title: const Text('放弃例外日期修改？'), actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('继续编辑')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('放弃'))
            ]));
    if (discard == true && mounted) {
      setState(() => allowExit = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: allowExit || !dirty,
      onPopInvoked: (didPop) {
        if (!didPop) _leave();
      },
      child: Scaffold(
          appBar: AppBar(title: Text(widget.date)),
          body: ListView(padding: const EdgeInsets.all(20), children: [
            const Text('本日替代时段',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
            const Text('不添加时段表示全天不可用，并切断前一日跨午夜时段。此处完成后还需保存整个计划。'),
            ScheduleWindowComposer(
                weekly: false,
                remaining: 8 - rows.length,
                onAdd: (values) => setState(() {
                      rows.addAll(values);
                      dirty = true;
                    })),
            for (int i = 0; i < rows.length; i++)
              ListTile(
                  title: Text(scheduleWindowLabel(rows[i])),
                  trailing: IconButton(
                      tooltip: '移除时段 ${i + 1}',
                      onPressed: () => setState(() {
                            rows.removeAt(i);
                            dirty = true;
                          }),
                      icon: const Icon(Icons.delete_outline))),
            FilledButton(
                onPressed: () {
                  if (!widget.isCurrent()) return;
                  setState(() => allowExit = true);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && widget.isCurrent()) {
                      Navigator.pop(context, rows);
                    }
                  });
                },
                child: Text(rows.isEmpty ? '设为当天全天不可用' : '使用这些例外时段')),
          ])));
}
