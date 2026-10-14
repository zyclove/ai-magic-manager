import 'package:flutter/material.dart';
import '../core/paged_collection.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import '../core/quotas.dart';

/// Every route and dialog is bound to the identity/workspace generation that opened it.
mixin _QuotaScope<T extends StatefulWidget> on State<T> {
  ParentSession get session;
  late final String tenant, actor, role;
  late final int generation;
  Route<dynamic>? dialog;
  bool get current =>
      mounted &&
      session.authenticated &&
      session.tenant?['id'] == tenant &&
      session.profile?['subject'] == actor &&
      session.role == role &&
      session.generation == generation &&
      const {'OWNER', 'GUARDIAN', 'ORG_ADMIN', 'AUDITOR'}.contains(role);
  String get root => '/tenants/$tenant';
  @override
  void initState() {
    super.initState();
    tenant = session.tenant!['id'];
    actor = session.profile!['subject'];
    role = session.role;
    generation = session.generation;
    session.addListener(_changed);
  }

  void _changed() {
    if (current || !mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      if (dialog?.isActive == true) dialog!.navigator?.removeRoute(dialog!);
      final route = ModalRoute.of(context);
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<bool> confirm(String title, String text, String action) async {
    final route = DialogRoute<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(title),
                content: SingleChildScrollView(child: Text(text)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('返回')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(action))
                ]));
    dialog = route;
    try {
      return await Navigator.of(context).push(route) == true && current;
    } finally {
      if (identical(dialog, route)) dialog = null;
    }
  }

  @override
  void dispose() {
    session.removeListener(_changed);
    super.dispose();
  }
}

class QuotaCenter extends StatefulWidget {
  final ParentSession session;
  final QuotaOperationStore? store;
  const QuotaCenter({super.key, required this.session, this.store});
  @override
  State<QuotaCenter> createState() => _QuotaCenterState();
}

class _QuotaCenterState extends State<QuotaCenter> with _QuotaScope {
  @override
  ParentSession get session => widget.session;
  late final PagedCollection pools;
  late final QuotaOperationController operation;
  final search = TextEditingController();
  bool opening = false;
  @override
  void initState() {
    super.initState();
    pools = PagedCollection(session.api, '$root/quota-pools',
        isCurrent: () => current, validateItem: readQuota);
    operation = QuotaOperationController(
        api: session.api,
        store: widget.store ?? QuotaOperationStore(),
        tenant: tenant,
        actor: actor,
        isCurrent: () => current && session.canDecide);
    if (session.canDecide) operation.load();
  }

  Future<void> _open([Json? pool]) async {
    if (!current || opening || operation.busy) return;
    setState(() => opening = true);
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => pool == null
              ? _QuotaEditor(session: session, operation: operation)
              : _QuotaDetail(
                  session: session, id: pool['id'], operation: operation)));
    } finally {
      if (mounted) setState(() => opening = false);
    }
    if (current) await pools.reload();
  }

  @override
  void dispose() {
    pools.dispose();
    operation.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('每日共享额度')),
      body: !current
          ? const Center(child: Text('当前工作空间已变化。'))
          : AnimatedBuilder(
              animation: Listenable.merge([pools, operation]),
              builder: (context, _) {
                final rows = pools.items
                    .where((r) => '${r['name']} ${r['periodId']}'
                        .contains(search.text.trim()))
                    .toList();
                return RefreshIndicator(
                    onRefresh: pools.reload,
                    child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(20),
                        children: [
                          Text('把每天的时间安排清楚',
                              style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 8),
                          const Text(
                              '总额度与单应用额度共同约束。这里显示服务端账本；是否能实际限制设备，取决于经验证的执行能力。'),
                          const SizedBox(height: 16),
                          if (session.canDecide) ...[
                            _QuotaRecovery(
                                session: session,
                                operation: operation,
                                confirm: confirm,
                                onCleared: pools.reload),
                            FilledButton.icon(
                                onPressed: opening ||
                                        operation.busy ||
                                        !operation.loaded ||
                                        operation.pending != null
                                    ? null
                                    : () => _open(),
                                icon: const Icon(Icons.add),
                                label: const Text('设置每日额度')),
                          ],
                          TextField(
                              controller: search,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                  labelText: '查找已加载的名称或日期',
                                  prefixIcon: Icon(Icons.search))),
                          if (pools.loading) const LinearProgressIndicator(),
                          if (pools.error != null)
                            _QuotaError(
                                error: pools.error!, retry: pools.reload),
                          if (pools.loaded && pools.items.isEmpty)
                            const Padding(
                                padding: EdgeInsets.all(20),
                                child: Text('还没有每日额度。先为孩子设置总额度，再按需细化到应用。')),
                          if (pools.loaded &&
                              pools.items.isNotEmpty &&
                              rows.isEmpty)
                            const Text('已加载的记录中没有匹配项，可调整搜索或继续加载。'),
                          for (final row in rows)
                            Card(
                                child: ListTile(
                                    title: Text(row['name']),
                                    subtitle: Text(
                                        '${row['periodId']} · ${row['scope'] == 'TOTAL' ? '总额度' : '指定应用'}\n可分配 ${quotaTime(row['availableSeconds'])} · 待确认 ${quotaTime(row['reservedSeconds'])}'),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: opening ? null : () => _open(row))),
                          if (pools.hasMore)
                            OutlinedButton(
                                onPressed:
                                    pools.loadingMore ? null : pools.loadMore,
                                child:
                                    Text(pools.loadingMore ? '正在加载…' : '加载更多')),
                        ]));
              }));
}

class _QuotaRecovery extends StatelessWidget {
  final ParentSession session;
  final QuotaOperationController operation;
  final Future<bool> Function(String, String, String) confirm;
  final Future<void> Function() onCleared;
  const _QuotaRecovery(
      {required this.session,
      required this.operation,
      required this.confirm,
      required this.onCleared});
  @override
  Widget build(BuildContext context) {
    final p = operation.pending,
        committed = operation.committed,
        latest = operation.latest;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (operation.busy) const LinearProgressIndicator(),
      if (operation.error != null)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(quotaFailure(operation.error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error))),
      if (!operation.loaded && !operation.busy)
        OutlinedButton(
            onPressed: operation.load, child: const Text('重新读取恢复记录')),
      if (p != null)
        Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(committed == null ? '先核对上一次额度操作' : '原操作已提交',
                          style: Theme.of(context).textTheme.titleLarge),
                      Text(p['operation'] == 'CREATE'
                          ? '创建：${p['body']['name']} · ${p['body']['periodId']}'
                          : '调整：${p['before']['name']} · ${p['body']['deltaSeconds'] > 0 ? '增加' : '减少'} ${quotaTime((p['body']['deltaSeconds'] as int).abs())}'),
                      const Text('内容已固定。网络异常不代表失败，不会自动再次增加额度。'),
                      if (committed != null)
                        Text(
                            '原操作后总额度：${quotaTime(committed['limitSeconds'])}（历史快照）'),
                      if (latest != null)
                        Text(
                            '最近核对的可分配额度：${quotaTime(latest['availableSeconds'])}'),
                      if (operation.queried && committed == null)
                        const Text('没有可读取的原结果。请核对每日额度和账本，不要据此认为未提交。'),
                      SelectableText('请求编号：${p['requestId']}'),
                      Wrap(spacing: 8, children: [
                        OutlinedButton(
                            onPressed: operation.busy ? null : operation.query,
                            child: const Text('核对原操作')),
                        if (committed == null)
                          OutlinedButton(
                              onPressed: operation.busy
                                  ? null
                                  : () async {
                                      if (await confirm(
                                          '重试原额度操作？',
                                          '将保留原内容、请求编号和资源版本。服务端会识别已提交操作；不会改成一次新的追加。',
                                          '重试原操作')) await operation.retry();
                                    },
                              child: const Text('重试原操作')),
                        if (operation.queried)
                          TextButton(
                              onPressed: operation.busy
                                  ? null
                                  : () async {
                                      if (committed == null &&
                                          !await confirm(
                                              '已核对账本？',
                                              '这里只清除本机提醒，不会撤销服务端操作。请确认已检查每日额度和账本。',
                                              '已核对，清除提醒')) return;
                                      if (await operation.acknowledge()) {
                                        await onCleared();
                                      }
                                    },
                              child: Text(
                                  committed == null ? '已核对，清除提醒' : '完成核对')),
                      ]),
                      if (operation.error is ParentApiException &&
                          (operation.error as ParentApiException).code ==
                              'REAUTH_REQUIRED') ...[
                        const Text('完成验证后重新打开每日额度，即可核对并重试原操作。'),
                        OutlinedButton(
                            onPressed:
                                operation.busy ? null : session.reauthenticate,
                            child: const Text('重新安全验证')),
                      ],
                    ]))),
    ]);
  }
}

class _QuotaDetail extends StatefulWidget {
  final ParentSession session;
  final String id;
  final QuotaOperationController operation;
  const _QuotaDetail(
      {required this.session, required this.id, required this.operation});
  @override
  State<_QuotaDetail> createState() => _QuotaDetailState();
}

class _QuotaDetailState extends State<_QuotaDetail> with _QuotaScope {
  @override
  ParentSession get session => widget.session;
  Json? pool;
  Object? error;
  bool loading = false;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (!current || loading) return;
    setState(() {
      loading = true;
      pool = null;
      error = null;
    });
    try {
      final result = readQuota(await session.api
          .object('$root/quota-pools/${widget.id}', isCurrent: () => current));
      if (result['id'] != widget.id) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (current) setState(() => pool = result);
    } catch (failure) {
      if (current) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('额度详情'), actions: [
        IconButton(
            tooltip: '刷新余额',
            onPressed: loading || !current ? null : _reload,
            icon: const Icon(Icons.refresh))
      ]),
      body: !current
          ? const SizedBox.shrink()
          : AnimatedBuilder(
              animation: widget.operation,
              builder: (context, _) =>
                  ListView(padding: const EdgeInsets.all(20), children: [
                    if (session.canDecide)
                      _QuotaRecovery(
                          session: session,
                          operation: widget.operation,
                          confirm: confirm,
                          onCleared: _reload),
                    if (loading) const LinearProgressIndicator(),
                    if (error != null)
                      _QuotaError(error: error!, retry: _reload),
                    if (pool != null) ...[
                      Text(pool!['name'],
                          style: Theme.of(context).textTheme.headlineSmall),
                      Text(
                          '${pool!['periodId']} · ${pool!['timeZone']} · ${pool!['scope'] == 'TOTAL' ? '儿童总额度' : '指定应用额度'}'),
                      QuotaBalanceCard(pool: pool!),
                      const Text('预留可能仍在等待离线设备结算，不会因断网自动返还。账本不证明设备已执行限制。'),
                      const SizedBox(height: 16),
                      if (session.canDecide)
                        FilledButton(
                            onPressed: widget.operation.busy ||
                                    !widget.operation.loaded ||
                                    widget.operation.pending != null
                                ? null
                                : () async {
                                    await Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                            builder: (_) => _QuotaEditor(
                                                session: session,
                                                operation: widget.operation,
                                                before: pool)));
                                    if (current) await _reload();
                                  },
                            child: const Text('增减当日额度')),
                      OutlinedButton(
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                  builder: (_) => _QuotaLedger(
                                      session: session, pool: pool!))),
                          child: const Text('查看额度账本')),
                      ExpansionTile(title: const Text('查看范围标识'), children: [
                        ListTile(
                            title: Text('儿童编号：${pool!['subjectId']}'),
                            subtitle: pool!['applicationId'] == null
                                ? null
                                : Text('应用编号：${pool!['applicationId']}'))
                      ]),
                    ],
                  ])));
}

/// Uses standard progress and text, preserving separate reserved/settled/available meaning.
class QuotaBalanceCard extends StatelessWidget {
  final Json pool;
  const QuotaBalanceCard({super.key, required this.pool});
  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('可分配 ${quotaTime(pool['availableSeconds'])}',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            LinearProgressIndicator(
                value: pool['limitSeconds'] == 0
                    ? 0
                    : pool['usedSeconds'] / pool['limitSeconds'],
                semanticsLabel: '已结算占总额度比例'),
            const SizedBox(height: 12),
            Wrap(spacing: 16, runSpacing: 8, children: [
              Text('总额度 ${quotaTime(pool['limitSeconds'])}'),
              Text('已结算 ${quotaTime(pool['usedSeconds'])}'),
              Text('待确认预留 ${quotaTime(pool['reservedSeconds'])}')
            ]),
          ])));
}

class _QuotaEditor extends StatefulWidget {
  final ParentSession session;
  final QuotaOperationController operation;
  final Json? before;
  const _QuotaEditor(
      {required this.session, required this.operation, this.before});
  @override
  State<_QuotaEditor> createState() => _QuotaEditorState();
}

class _QuotaEditorState extends State<_QuotaEditor> with _QuotaScope {
  @override
  ParentSession get session => widget.session;
  final name = TextEditingController(), minutes = TextEditingController();
  final form = GlobalKey<FormState>();
  Json? child, application, calendar;
  String? date;
  bool adding = true, reading = false;
  Object? error;
  Future<void> _pick(bool subject) async {
    if (!current || reading || widget.operation.busy) return;
    final row = await Navigator.of(context).push<Json>(MaterialPageRoute(
        builder: (_) => _QuotaPicker(session: session, subject: subject)));
    if (!current || row == null) return;
    if (!subject) {
      setState(() => application = row);
      return;
    }
    setState(() {
      child = row;
      calendar = null;
      date = null;
      error = null;
      reading = true;
    });
    try {
      final query = Uri(queryParameters: {
        'subjectId': row['id'],
        'defaultTimeZone': session.tenant?['timeZone'] ?? 'Asia/Shanghai'
      }).query;
      final result = await session.api.object(
          '$root/quota-plans/calendar?$query',
          isCurrent: () => current);
      if (!current) return;
      if (result['subjectId'] != row['id'] ||
          result['timeZone'] is! String ||
          result['timeZone'].isEmpty ||
          result['timeZone'].length > 100 ||
          !quotaDate(result['currentDate'])) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      setState(() {
        calendar = result;
        date = result['currentDate'];
        if (name.text.trim().isEmpty) name.text = '${row['nickname']} · 每日额度';
      });
    } catch (failure) {
      if (current) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => reading = false);
    }
  }

  Future<void> _date() async {
    final today = DateTime.parse('${calendar!['currentDate']}T00:00:00Z');
    final route = DialogRoute<DateTime>(
        context: context,
        builder: (_) => DatePickerDialog(
            initialDate: DateTime.parse(date!),
            firstDate: today,
            lastDate: today.add(const Duration(days: 366))));
    dialog = route;
    final value = await Navigator.of(context).push(route);
    if (identical(dialog, route)) dialog = null;
    if (current && value != null) {
      setState(() => date =
          '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}');
    }
  }

  Future<void> _save() async {
    if (!current ||
        !session.canDecide ||
        reading ||
        widget.operation.busy ||
        !form.currentState!.validate()) return;
    if (widget.before == null &&
        (child == null || calendar == null || date == null)) {
      setState(() => error = const FormatException('请先选择儿童并读取额度日期。'));
      return;
    }
    final count = int.parse(minutes.text.trim());
    final Json body = widget.before == null
        ? {
            'name': name.text.trim(),
            'subjectId': child!['id'],
            'scope': application == null ? 'TOTAL' : 'APPLICATION',
            if (application != null) 'applicationId': application!['id'],
            'periodId': date,
            'timeZone': calendar!['timeZone'],
            'limitSeconds': count * 60,
          }
        : {
            'deltaSeconds': count * 60 * (adding ? 1 : -1),
            'reason': adding ? 'EXTRA_TIME' : 'CORRECTION'
          };
    try {
      validateQuotaInput(
          widget.before == null ? 'CREATE' : 'ADJUST', body, widget.before);
    } catch (failure) {
      setState(() => error = failure);
      return;
    }
    if (!await confirm(
        widget.before == null ? '创建这一天的额度？' : '确认调整额度？',
        widget.before == null
            ? '${child!['nickname']} · $date\n${calendar!['timeZone']}\n${application?['displayName'] ?? '所有适用应用总额度'}：$count 分钟。'
            : '${widget.before!['name']} · ${widget.before!['periodId']}\n${adding ? '增加' : '减少'} $count 分钟；账本会保留本次调整。',
        '确认提交')) return;
    await widget.operation.submit(
        widget.before == null ? 'CREATE' : 'ADJUST', body,
        before: widget.before);
  }

  @override
  void dispose() {
    name.dispose();
    minutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(widget.before == null ? '设置每日额度' : '调整当日额度')),
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
                          absorbing: reading || widget.operation.busy,
                          child: Form(
                              key: form,
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    const Text(
                                        '保存需要管理员近期安全验证。这里设置服务端额度，不代表设备已经执行限制。'),
                                    const SizedBox(height: 16),
                                    if (widget.before == null) ...[
                                      OutlinedButton.icon(
                                          onPressed: () => _pick(true),
                                          icon:
                                              const Icon(Icons.person_outline),
                                          label: Text(child == null
                                              ? '1. 选择儿童或学生'
                                              : '儿童：${child!['nickname']}')),
                                      OutlinedButton(
                                          onPressed: () => _pick(false),
                                          child: Text(application == null
                                              ? '2. 总额度（可选择单个应用）'
                                              : '应用：${application!['displayName']}')),
                                      if (application != null)
                                        TextButton(
                                            onPressed: () => setState(
                                                () => application = null),
                                            child: const Text('改为总额度')),
                                      if (calendar != null)
                                        ListTile(
                                            title: Text('日期：$date'),
                                            subtitle: Text(
                                                '额度时区：${calendar!['timeZone']}'),
                                            trailing: const Icon(
                                                Icons.calendar_month),
                                            onTap: _date),
                                      TextFormField(
                                          controller: name,
                                          maxLength: 100,
                                          decoration: const InputDecoration(
                                              labelText: '额度名称'),
                                          validator: (v) =>
                                              v == null || v.trim().isEmpty
                                                  ? '请输入名称'
                                                  : null),
                                    ] else ...[
                                      Text(
                                          '${widget.before!['name']} · ${widget.before!['periodId']}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleLarge),
                                      QuotaBalanceCard(pool: widget.before!),
                                      DropdownButtonFormField<bool>(
                                          value: adding,
                                          isExpanded: true,
                                          decoration: const InputDecoration(
                                              labelText: '调整方式'),
                                          items: const [
                                            DropdownMenuItem(
                                                value: true,
                                                child: Text('增加使用时间')),
                                            DropdownMenuItem(
                                                value: false,
                                                child: Text('减少额度'))
                                          ],
                                          onChanged: (v) =>
                                              setState(() => adding = v!)),
                                    ],
                                    TextFormField(
                                        controller: minutes,
                                        maxLength: 4,
                                        keyboardType: TextInputType.number,
                                        decoration: InputDecoration(
                                            labelText: widget.before == null
                                                ? '额度（分钟，0–1440）'
                                                : '调整分钟数（1–1440）',
                                            helperText: widget.before == null
                                                ? '0 表示不分配可用时间'
                                                : '减少额度不能扣除已结算或待确认预留'),
                                        validator: (v) {
                                          final n =
                                              int.tryParse(v?.trim() ?? '');
                                          return n == null ||
                                                  n <
                                                      (widget.before == null
                                                          ? 0
                                                          : 1) ||
                                                  n > 1440
                                              ? '请输入范围内的整数分钟'
                                              : null;
                                        }),
                                    if (reading)
                                      const LinearProgressIndicator(),
                                    if (error != null)
                                      Text(quotaFailure(error!),
                                          style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .error)),
                                    const SizedBox(height: 20),
                                    FilledButton(
                                        onPressed: _save,
                                        child: const Text('检查并提交')),
                                  ]))),
                  ])));
}

class _QuotaPicker extends StatefulWidget {
  final ParentSession session;
  final bool subject;
  const _QuotaPicker({required this.session, required this.subject});
  @override
  State<_QuotaPicker> createState() => _QuotaPickerState();
}

class _QuotaPickerState extends State<_QuotaPicker> with _QuotaScope {
  @override
  ParentSession get session => widget.session;
  late final PagedCollection rows;
  @override
  void initState() {
    super.initState();
    rows = PagedCollection(
        session.api, '$root/${widget.subject ? 'subjects' : 'applications'}',
        isCurrent: () => current,
        validateItem: (row) =>
            validateQuotaEntity(row, subject: widget.subject));
  }

  @override
  void dispose() {
    rows.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(widget.subject ? '选择儿童或学生' : '选择应用')),
      body: !current
          ? const SizedBox.shrink()
          : AnimatedBuilder(
              animation: rows,
              builder: (context, _) =>
                  ListView(padding: const EdgeInsets.all(20), children: [
                    if (rows.loading) const LinearProgressIndicator(),
                    if (rows.error != null)
                      _QuotaError(error: rows.error!, retry: rows.reload),
                    if (rows.loaded && rows.items.isEmpty)
                      Text(widget.subject ? '请先在儿童档案中添加孩子。' : '请先在应用目录登记应用。'),
                    for (final row in rows.items)
                      Card(
                          child: ListTile(
                              title: Text(
                                  '${row[widget.subject ? 'nickname' : 'displayName']}'),
                              subtitle: Text(widget.subject
                                  ? row['id']
                                  : '${row['packageName']} · ${row['profile']}'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () {
                                if (current) Navigator.pop(context, row);
                              })),
                    if (rows.hasMore)
                      OutlinedButton(
                          onPressed: rows.loadingMore ? null : rows.loadMore,
                          child: const Text('加载更多')),
                  ])));
}

class _QuotaLedger extends StatefulWidget {
  final ParentSession session;
  final Json pool;
  const _QuotaLedger({required this.session, required this.pool});
  @override
  State<_QuotaLedger> createState() => _QuotaLedgerState();
}

class _QuotaLedgerState extends State<_QuotaLedger> with _QuotaScope {
  @override
  ParentSession get session => widget.session;
  late final PagedCollection rows;
  @override
  void initState() {
    super.initState();
    rows = PagedCollection(
        session.api, '$root/quota-pools/${widget.pool['id']}/ledger',
        isCurrent: () => current, validateItem: validateQuotaLedger);
  }

  @override
  void dispose() {
    rows.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('额度账本')),
      body: !current
          ? const SizedBox.shrink()
          : AnimatedBuilder(
              animation: rows,
              builder: (context, _) =>
                  ListView(padding: const EdgeInsets.all(20), children: [
                    Text('${widget.pool['name']} · ${widget.pool['periodId']}'),
                    const Text('时间按手机当地时区显示；账本周期按额度时区计算。'),
                    if (rows.loading) const LinearProgressIndicator(),
                    if (rows.error != null)
                      _QuotaError(error: rows.error!, retry: rows.reload),
                    if (rows.loaded && rows.items.isEmpty)
                      const Text('暂无账本记录。'),
                    for (final row in rows.items)
                      Card(
                          child: ListTile(
                              title: Text(switch (row['kind']) {
                                'CREATED' => '创建额度',
                                'ADJUSTED' => '调整额度',
                                'RESERVED' => '预留使用时间',
                                'SETTLED' => '结算使用时间',
                                'RELEASED' => '释放未使用预留',
                                _ => '${row['kind']}'
                              }),
                              subtitle: Text(
                                  '${DateTime.fromMillisecondsSinceEpoch(row['occurredAt']).toLocal()}\n总额度 ${quotaDelta(row['limitDelta'])} · 已结算 ${quotaDelta(row['usedDelta'])} · 待确认预留 ${quotaDelta(row['reservedDelta'])}'))),
                    if (rows.hasMore)
                      OutlinedButton(
                          onPressed: rows.loadingMore ? null : rows.loadMore,
                          child: const Text('加载更多')),
                  ])));
}

class _QuotaError extends StatelessWidget {
  final Object error;
  final Future<void> Function() retry;
  const _QuotaError({required this.error, required this.retry});
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(quotaFailure(error),
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
        OutlinedButton(onPressed: retry, child: const Text('重新读取'))
      ]);
}
