part of 'quota_center.dart';

/// A weekly overview always includes text values; bar lengths only aid comparison.
class QuotaWeekOverview extends StatelessWidget {
  final Map<String, dynamic> limits;
  const QuotaWeekOverview({super.key, required this.limits});
  @override
  Widget build(BuildContext context) {
    final max = limits.values.cast<int>().fold<int>(1, (a, b) => a > b ? a : b);
    return Column(
        children: List.generate(7, (index) {
      final value = limits[quotaWeekDays[index]] as int;
      return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Semantics(
              label: '${quotaWeekLabels[index]}，${quotaTime(value)}',
              child: ExcludeSemantics(
                  child: Row(children: [
                SizedBox(width: 44, child: Text(quotaWeekLabels[index])),
                Expanded(
                    child: LinearProgressIndicator(
                        value: value / max,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4))),
                const SizedBox(width: 12),
                Text(quotaTime(value)),
              ]))));
    }));
  }
}

class _QuotaPlanCenter extends StatefulWidget {
  final ParentSession session;
  final QuotaOperationController operation;
  const _QuotaPlanCenter({required this.session, required this.operation});
  @override
  State<_QuotaPlanCenter> createState() => _QuotaPlanCenterState();
}

class _QuotaPlanCenterState extends State<_QuotaPlanCenter> with _QuotaScope {
  @override
  ParentSession get session => widget.session;
  late final PagedCollection plans;
  bool opening = false;
  @override
  void initState() {
    super.initState();
    plans = PagedCollection(session.api, '$root/quota-plans',
        isCurrent: () => current, validateItem: readQuotaPlan);
  }

  Future<void> _open([Json? plan]) async {
    if (!current || opening || widget.operation.busy) return;
    setState(() => opening = true);
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => plan == null
              ? _QuotaPlanEditor(session: session, operation: widget.operation)
              : _QuotaPlanDetail(
                  session: session,
                  operation: widget.operation,
                  id: plan['id'])));
    } finally {
      if (mounted) setState(() => opening = false);
    }
    if (current) await plans.reload();
  }

  @override
  void dispose() {
    plans.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('每周自动安排')),
      body: !current
          ? const SizedBox.shrink()
          : AnimatedBuilder(
              animation: Listenable.merge([plans, widget.operation]),
              builder: (context, _) => RefreshIndicator(
                  onRefresh: plans.reload,
                  child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(20),
                      children: [
                        Text('安排一周，每天自动生成额度',
                            style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 8),
                        const Text('工作日和周末可分别设置。已有的当天额度不会被计划覆盖；修改、暂停和恢复从次日开始。'),
                        const SizedBox(height: 16),
                        if (session.canDecide) ...[
                          _QuotaRecovery(
                              session: session,
                              operation: widget.operation,
                              confirm: confirm,
                              onCleared: plans.reload),
                          FilledButton.icon(
                              onPressed: opening ||
                                      widget.operation.busy ||
                                      !widget.operation.loaded ||
                                      widget.operation.pending != null
                                  ? null
                                  : () => _open(),
                              icon: const Icon(Icons.add),
                              label: const Text('创建每周计划')),
                        ],
                        if (plans.loading) const LinearProgressIndicator(),
                        if (plans.error != null)
                          _QuotaError(error: plans.error!, retry: plans.reload),
                        if (plans.loaded && plans.items.isEmpty)
                          const Padding(
                              padding: EdgeInsets.symmetric(vertical: 32),
                              child: Text('还没有每周计划。先选择儿童，填写七天的额度即可开始。')),
                        for (final plan in plans.items)
                          Card(
                              child: ListTile(
                                  leading: Icon(plan['state'] == 'PAUSED'
                                      ? Icons.pause_circle_outline
                                      : Icons.event_repeat),
                                  title: Text(plan['name']),
                                  subtitle: Text(
                                      '${plan['scope'] == 'TOTAL' ? '总额度' : '指定应用'} · ${plan['timeZone']}\n'
                                      '最新安排：${plan['effectiveFrom']} 起${plan['state'] == 'PAUSED' ? '暂停' : '启用'} · 版本 ${plan['version']}'),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: opening ? null : () => _open(plan))),
                        if (plans.hasMore)
                          OutlinedButton(
                              onPressed:
                                  plans.loadingMore ? null : plans.loadMore,
                              child:
                                  Text(plans.loadingMore ? '正在加载…' : '加载更多')),
                      ]))));
}

class _QuotaPlanDetail extends StatefulWidget {
  final ParentSession session;
  final QuotaOperationController operation;
  final String id;
  const _QuotaPlanDetail(
      {required this.session, required this.operation, required this.id});
  @override
  State<_QuotaPlanDetail> createState() => _QuotaPlanDetailState();
}

class _QuotaPlanDetailState extends State<_QuotaPlanDetail> with _QuotaScope {
  @override
  ParentSession get session => widget.session;
  Json? plan;
  Object? error;
  bool loading = false, opening = false;
  late final QuotaRevisionController revisions;
  @override
  void initState() {
    super.initState();
    revisions = QuotaRevisionController(
        session.api, '$root/quota-plans/${widget.id}/revisions', () => current);
    _reload();
  }

  Future<void> _reload() async {
    if (!current || loading) return;
    setState(() {
      loading = true;
      error = null;
      plan = null;
    });
    try {
      final result = readQuotaPlan(await session.api
          .object('$root/quota-plans/${widget.id}', isCurrent: () => current));
      if (result['id'] != widget.id) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (current) setState(() => plan = result);
    } catch (failure) {
      if (current) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => loading = false);
    }
    if (current && revisions.loaded) await revisions.load(reload: true);
  }

  Future<void> _edit() async {
    if (!current || opening || plan == null) return;
    setState(() => opening = true);
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => _QuotaPlanEditor(
              session: session, operation: widget.operation, before: plan)));
    } finally {
      if (mounted) setState(() => opening = false);
    }
    if (current) await _reload();
  }

  Future<void> _toggle() async {
    final before = plan!;
    final pause = before['state'] == 'ACTIVE';
    if (!await confirm(
        pause ? '从明天暂停计划？' : '从明天恢复计划？',
        '按 ${before['timeZone']} 的日期计算。今天已经生成的额度继续有效，已用时间和预留不会清零。',
        pause ? '明天暂停' : '明天恢复')) return;
    await widget.operation.submit(
        'PLAN_UPDATE',
        {
          'name': before['name'],
          'state': pause ? 'PAUSED' : 'ACTIVE',
          'weeklyLimits': before['weeklyLimits'],
          'dateOverrides': before['dateOverrides'],
        },
        before: before);
  }

  @override
  void dispose() {
    revisions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('每周计划'), actions: [
        IconButton(
            tooltip: '刷新计划',
            onPressed: !current || loading ? null : _reload,
            icon: const Icon(Icons.refresh))
      ]),
      body: !current
          ? const SizedBox.shrink()
          : AnimatedBuilder(
              animation: Listenable.merge([widget.operation, revisions]),
              builder: (context, _) {
                final enabled = !opening &&
                    !loading &&
                    !widget.operation.busy &&
                    widget.operation.loaded &&
                    widget.operation.pending == null;
                return ListView(padding: const EdgeInsets.all(20), children: [
                  if (session.canDecide)
                    _QuotaRecovery(
                        session: session,
                        operation: widget.operation,
                        confirm: confirm,
                        onCleared: _reload),
                  if (loading) const LinearProgressIndicator(),
                  if (error != null) _QuotaError(error: error!, retry: _reload),
                  if (plan != null) ...[
                    Text(plan!['name'],
                        style: Theme.of(context).textTheme.headlineSmall),
                    Text(
                        '最新保存：版本 ${plan!['version']} · ${plan!['effectiveFrom']} 起'
                        '${plan!['state'] == 'PAUSED' ? '暂停' : '启用'}\n额度时区：${plan!['timeZone']}'),
                    const SizedBox(height: 16),
                    QuotaWeekOverview(
                        limits:
                            Map<String, dynamic>.from(plan!['weeklyLimits'])),
                    const SizedBox(height: 12),
                    const Text('图中为最新保存安排。今日实际额度请在“每日共享额度”中查看；设备执行能力需单独确认。'),
                    if (session.canDecide)
                      Wrap(spacing: 8, children: [
                        FilledButton.icon(
                            onPressed: enabled ? _edit : null,
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('修改安排')),
                        OutlinedButton(
                            onPressed: enabled ? _toggle : null,
                            child: Text(
                                plan!['state'] == 'PAUSED' ? '明天恢复' : '明天暂停')),
                      ]),
                    ExpansionTile(
                        title: Text(
                            '特殊日期（${(plan!['dateOverrides'] as Map).length}）'),
                        children: [
                          for (final e
                              in (plan!['dateOverrides'] as Map).entries)
                            ListTile(
                                title: Text(e.key),
                                trailing: Text(quotaTime(e.value)))
                        ]),
                    ExpansionTile(
                        title: const Text('版本记录'),
                        onExpansionChanged: (open) {
                          if (open && !revisions.loaded) revisions.load();
                        },
                        children: [
                          if (revisions.busy) const LinearProgressIndicator(),
                          if (revisions.error != null)
                            _QuotaError(
                                error: revisions.error!,
                                retry: () => revisions.load()),
                          for (final revision in revisions.items)
                            ExpansionTile(
                                title: Text(
                                    '版本 ${revision['version']} · ${revision['effectiveFrom']} 起'
                                    '${revision['configuration']['state'] == 'PAUSED' ? '暂停' : '启用'}'),
                                children: [
                                  Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(children: [
                                        Text(revision['configuration']['name']),
                                        QuotaWeekOverview(
                                            limits: Map<String, dynamic>.from(
                                                revision['configuration']
                                                    ['weeklyLimits'])),
                                        for (final e
                                            in (revision['configuration']
                                                    ['dateOverrides'] as Map)
                                                .entries)
                                          ListTile(
                                              title: Text(e.key),
                                              trailing:
                                                  Text(quotaTime(e.value))),
                                      ]))
                                ]),
                          if (revisions.cursor != null)
                            TextButton(
                                onPressed: revisions.busy
                                    ? null
                                    : () => revisions.load(),
                                child: const Text('加载更早版本')),
                        ]),
                  ],
                ]);
              }));
}

class _QuotaPlanEditor extends StatefulWidget {
  final ParentSession session;
  final QuotaOperationController operation;
  final Json? before;
  const _QuotaPlanEditor(
      {required this.session, required this.operation, this.before});
  @override
  State<_QuotaPlanEditor> createState() => _QuotaPlanEditorState();
}

class _QuotaPlanEditorState extends State<_QuotaPlanEditor> with _QuotaScope {
  @override
  ParentSession get session => widget.session;
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  final days = List.generate(7, (_) => TextEditingController());
  final dates = <String, int>{};
  Json? child, application, calendar;
  bool reading = false, tomorrow = true, picking = false;
  Object? error;
  @override
  void initState() {
    super.initState();
    final before = widget.before;
    if (before != null) {
      name.text = before['name'];
      for (var i = 0; i < 7; i++) {
        days[i].text =
            quotaMinutesInput(before['weeklyLimits'][quotaWeekDays[i]]);
      }
      dates.addAll(Map<String, int>.from(before['dateOverrides']));
      _calendar(before['subjectId']);
    }
  }

  Future<void> _calendar(String subjectId) async {
    if (!current || reading) return;
    setState(() {
      reading = true;
      calendar = null;
      error = null;
    });
    try {
      final query = Uri(queryParameters: {
        'subjectId': subjectId,
        'defaultTimeZone': widget.before?['timeZone'] ??
            session.tenant?['timeZone'] ??
            'Asia/Shanghai'
      }).query;
      final result = await session.api.object(
          '$root/quota-plans/calendar?$query',
          isCurrent: () => current);
      if (!current) return;
      if (result['subjectId'] != subjectId ||
          result['timeZone'] is! String ||
          result['timeZone'].isEmpty ||
          result['timeZone'].length > 100 ||
          !quotaDate(result['currentDate']) ||
          (widget.before != null &&
              result['timeZone'] != widget.before!['timeZone'])) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      setState(() => calendar = result);
    } catch (failure) {
      if (current) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => reading = false);
    }
  }

  Future<void> _pick(bool subject) async {
    if (!current || picking || reading) return;
    setState(() => picking = true);
    try {
      final row = await Navigator.of(context).push<Json>(MaterialPageRoute(
          builder: (_) => _QuotaPicker(session: session, subject: subject)));
      if (!current || row == null) return;
      if (subject) {
        setState(() {
          child = row;
          if (name.text.trim().isEmpty) name.text = '${row['nickname']} · 每周安排';
        });
        await _calendar(row['id']);
      } else {
        setState(() => application = row);
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  String _day(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  String get _start =>
      _day(DateTime.parse('${calendar!['currentDate']}T00:00:00Z')
          .add(Duration(days: widget.before != null || tomorrow ? 1 : 0)));
  Future<int?> _minutes(String title, {int? initial}) async {
    final controller = TextEditingController(
        text: initial == null ? '' : quotaMinutesInput(initial));
    final key = GlobalKey<FormState>();
    final route = DialogRoute<int>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(title),
                content: Form(
                    key: key,
                    child: TextFormField(
                        autofocus: true,
                        controller: controller,
                        keyboardType: TextInputType.datetime,
                        decoration: const InputDecoration(
                            labelText: '分钟数',
                            helperText: '0–1440 分钟；也可输入 30:15 表示 30 分 15 秒'),
                        validator: (v) => parseQuotaMinutes(v ?? '') == null
                            ? '请输入有效额度'
                            : null)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () {
                        if (key.currentState!.validate()) {
                          Navigator.pop(
                              ctx, parseQuotaMinutes(controller.text));
                        }
                      },
                      child: const Text('应用'))
                ]));
    dialog = route;
    try {
      final value = await Navigator.of(context).push(route);
      return current ? value : null;
    } finally {
      if (identical(dialog, route)) dialog = null;
      await route.completed;
      controller.dispose();
    }
  }

  Future<void> _fill(bool weekend) async {
    final value = await _minutes(weekend ? '周末每天多少分钟？' : '工作日每天多少分钟？');
    if (value != null && current) {
      setState(() {
        for (final i in weekend ? [5, 6] : [0, 1, 2, 3, 4]) {
          days[i].text = quotaMinutesInput(value);
        }
      });
    }
  }

  Future<void> _date([String? existing]) async {
    if (!current || calendar == null) return;
    String? date = existing;
    if (date == null) {
      final first = DateTime.parse('${calendar!['currentDate']}T00:00:00Z');
      final route = DialogRoute<DateTime>(
          context: context,
          builder: (_) => DatePickerDialog(
              initialDate: DateTime.parse(_start),
              firstDate: first,
              lastDate: first.add(const Duration(days: 366))));
      dialog = route;
      final selected = await Navigator.of(context).push(route);
      if (identical(dialog, route)) dialog = null;
      if (!current || selected == null) return;
      date = _day(selected);
    }
    final value = await _minutes('$date 的额度', initial: dates[date]);
    if (current && value != null) setState(() => dates[date!] = value);
  }

  Future<void> _save() async {
    if (!current ||
        !session.canDecide ||
        calendar == null ||
        reading ||
        picking ||
        widget.operation.busy ||
        !widget.operation.loaded ||
        widget.operation.pending != null ||
        !form.currentState!.validate()) return;
    final Json body = {
      'name': name.text.trim(),
      'weeklyLimits': {
        for (var i = 0; i < 7; i++)
          quotaWeekDays[i]: parseQuotaMinutes(days[i].text)
      },
      'dateOverrides': Map<String, int>.from(dates),
      if (widget.before == null) ...{
        'subjectId': child!['id'],
        'scope': application == null ? 'TOTAL' : 'APPLICATION',
        if (application != null) 'applicationId': application!['id'],
        'timeZone': calendar!['timeZone'],
        'effectiveFrom': _start,
      } else
        'state': widget.before!['state'],
    };
    if (!await confirm(
        '保存这份每周安排？',
        '${body['name']}\n$_start 起生效 · ${calendar!['timeZone']}\n'
            '${List.generate(7, (i) => '${quotaWeekLabels[i]} ${quotaTime(body['weeklyLimits'][quotaWeekDays[i]])}').join('、')}\n'
            '特殊日期 ${dates.length} 个。已有当天额度、已用时间和预留不会被重置。',
        '确认保存')) return;
    await widget.operation.submit(
        widget.before == null ? 'PLAN_CREATE' : 'PLAN_UPDATE', body,
        before: widget.before);
  }

  @override
  void dispose() {
    name.dispose();
    for (final day in days) {
      day.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(widget.before == null ? '创建每周计划' : '修改每周安排')),
      body: !current
          ? const SizedBox.shrink()
          : AnimatedBuilder(
              animation: widget.operation,
              builder: (context, _) =>
                  ListView(padding: const EdgeInsets.all(20), children: [
                    _QuotaRecovery(
                        session: session,
                        operation: widget.operation,
                        confirm: confirm,
                        onCleared: () async {
                          if (current) Navigator.pop(context);
                        }),
                    if (widget.operation.pending == null)
                      AbsorbPointer(
                          absorbing:
                              reading || picking || widget.operation.busy,
                          child: Form(
                              key: form,
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (widget.before == null) ...[
                                      OutlinedButton.icon(
                                          onPressed: () => _pick(true),
                                          icon:
                                              const Icon(Icons.person_outline),
                                          label: Text(child == null
                                              ? '选择儿童或学生'
                                              : '儿童：${child!['nickname']}')),
                                      ExpansionTile(
                                          title: Text(application == null
                                              ? '适用范围：总额度'
                                              : '应用：${application!['displayName']}'),
                                          children: [
                                            TextButton(
                                                onPressed: () => _pick(false),
                                                child: const Text('选择单个应用')),
                                            if (application != null)
                                              TextButton(
                                                  onPressed: () => setState(
                                                      () => application = null),
                                                  child: const Text('改为总额度'))
                                          ]),
                                    ],
                                    TextFormField(
                                        controller: name,
                                        maxLength: 100,
                                        decoration: const InputDecoration(
                                            labelText: '计划名称'),
                                        validator: (v) =>
                                            v == null || v.trim().isEmpty
                                                ? '请输入名称'
                                                : null),
                                    const SizedBox(height: 16),
                                    Text('一周额度',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge),
                                    const Text('先批量填写，再按天微调。0 表示当天不分配时间。'),
                                    Wrap(spacing: 8, children: [
                                      OutlinedButton(
                                          onPressed: () => _fill(false),
                                          child: const Text('填写工作日')),
                                      OutlinedButton(
                                          onPressed: () => _fill(true),
                                          child: const Text('填写周末')),
                                    ]),
                                    for (var i = 0; i < 7; i++)
                                      Padding(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 5),
                                          child: TextFormField(
                                              controller: days[i],
                                              keyboardType:
                                                  TextInputType.datetime,
                                              decoration: InputDecoration(
                                                  labelText: quotaWeekLabels[i],
                                                  suffixText: '分钟',
                                                  hintText:
                                                      '0–1440；可用 30:15 保留秒数'),
                                              validator: (v) =>
                                                  parseQuotaMinutes(v ?? '') ==
                                                          null
                                                      ? '请输入 0–1440 分钟'
                                                      : null)),
                                    ExpansionTile(
                                        title: Text('特殊日期（${dates.length}）'),
                                        subtitle:
                                            const Text('例如假期；指定日期优先于每周安排'),
                                        children: [
                                          for (final date
                                              in dates.keys.toList()..sort())
                                            ListTile(
                                                title: Text(date),
                                                subtitle: Text(
                                                    quotaTime(dates[date]!)),
                                                onTap: () => _date(date),
                                                trailing: IconButton(
                                                    tooltip: '移除 $date 的例外',
                                                    icon: const Icon(Icons
                                                        .remove_circle_outline),
                                                    onPressed: () => setState(
                                                        () => dates
                                                            .remove(date)))),
                                          TextButton.icon(
                                              onPressed: calendar == null ||
                                                      dates.length >= 60
                                                  ? null
                                                  : () => _date(),
                                              icon: const Icon(Icons.add),
                                              label: const Text(
                                                  '添加特殊日期（最多 60 个）')),
                                        ]),
                                    if (calendar != null) ...[
                                      if (widget.before == null)
                                        SwitchListTile(
                                            title: const Text('从明天开始'),
                                            subtitle: const Text(
                                                '关闭后从今天开始；已有当天额度仍保留'),
                                            value: tomorrow,
                                            onChanged: (v) =>
                                                setState(() => tomorrow = v)),
                                      Card(
                                          child: Padding(
                                              padding: const EdgeInsets.all(16),
                                              child: Text(
                                                  '$_start 起生效 · ${calendar!['timeZone']}\n'
                                                  '${widget.before?['state'] == 'PAUSED' ? '此计划仍保持暂停；保存不会恢复计划。' : '不会重置已经生成的当天额度。'}'))),
                                    ],
                                    if (reading)
                                      const LinearProgressIndicator(),
                                    if (error != null)
                                      _QuotaError(
                                          error: error!,
                                          retry: () => _calendar(
                                              widget.before?['subjectId'] ??
                                                  child!['id'])),
                                    const SizedBox(height: 16),
                                    FilledButton.icon(
                                        onPressed: calendar == null ||
                                                !widget.operation.loaded
                                            ? null
                                            : _save,
                                        icon: const Icon(Icons.check),
                                        label: const Text('预览并保存')),
                                  ]))),
                  ])));
}
