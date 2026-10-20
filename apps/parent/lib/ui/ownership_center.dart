import 'operation_result_terminal_panel.dart';
import 'package:flutter/material.dart';
import '../core/member_access.dart';
import '../core/ownership.dart';
import '../core/paged_collection.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';

/// Also reachable by a recipient guardian/auditor, who cannot open member administration.
class OwnershipEntry extends StatelessWidget {
  final ParentSession session;
  const OwnershipEntry({super.key, required this.session});
  @override
  Widget build(BuildContext context) =>
      session.tenant == null || !ownershipRoles.contains(session.role)
          ? const SizedBox.shrink()
          : OutlinedButton.icon(
              onPressed: session.busy
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => OwnershipCenter(session: session))),
              icon: const Icon(Icons.swap_horiz_outlined),
              label: const Text('所有者交接'));
}

class OwnershipCenter extends StatefulWidget {
  final ParentSession session;
  final OwnershipStore? store;
  const OwnershipCenter({super.key, required this.session, this.store});
  @override
  State<OwnershipCenter> createState() => _OwnershipCenterState();
}

class _OwnershipCenterState extends State<OwnershipCenter>
    with WidgetsBindingObserver {
  ParentSession get session => widget.session;
  late final String tenant, actor, role, kind, name;
  late final int generation, tenantVersion;
  late final PagedCollection transfers;
  PagedCollection? members;
  late final OwnershipOperation operation;
  final search = TextEditingController();
  bool foreground = true, loading = false, choosing = false;
  Json? selected, recipient;
  Object? error;
  Route<dynamic>? dialog;
  bool get current =>
      mounted &&
      !_operationOwnerLost &&
      session.authenticated &&
      session.tenant?['id'] == tenant &&
      session.profile?['subject'] == actor &&
      session.role == role &&
      session.generation == generation &&
      ownershipRoles.contains(role);
  bool get available => current && foreground;
  bool get idle =>
      available &&
      !loading &&
      !operation.busy &&
      operation.loaded &&
      operation.pending == null;
  String get path => '/tenants/$tenant/ownership-transfers';
  String get formerRole => kind == 'FAMILY' ? 'GUARDIAN' : 'ORG_ADMIN';
  bool _operationOwnerLost = false;
  @override
  void deactivate() {
    _operationOwnerLost = true;
    super.deactivate();
  }

  @override
  void initState() {
    super.initState();
    tenant = session.tenant!['id'];
    name = session.tenant!['name'];
    kind = session.tenant!['kind'];
    tenantVersion = session.tenant!['version'];
    actor = session.profile!['subject'];
    role = session.role;
    generation = session.generation;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    session.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    transfers = PagedCollection(session.api, path,
        isCurrent: () => available,
        validateItem: (r) => readOwnership(r, tenant));
    operation = OwnershipOperation(
        api: session.api,
        tenant: tenant,
        actor: actor,
        store: widget.store ?? OwnershipStore(),
        isCurrent: () => available);
    operation.load();
  }

  void _changed() {
    if (!mounted || current) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      if (dialog?.isActive == true) dialog!.navigator?.removeRoute(dialog!);
      final route = ModalRoute.of(context);
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) operation.suspend();
    if (!foreground && dialog?.isActive == true) {
      dialog!.navigator?.removeRoute(dialog!);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    session.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    transfers.dispose();
    members?.dispose();
    operation.dispose();
    search.dispose();
    super.dispose();
  }

  Future<bool> confirm(String title, String body, String label) async {
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
                      child: Text(label))
                ]));
    dialog = route;
    try {
      return await Navigator.of(context).push(route) == true && available;
    } finally {
      if (identical(dialog, route)) dialog = null;
    }
  }

  String date(int value) {
    final d = DateTime.fromMillisecondsSinceEpoch(value).toLocal(),
        l = MaterialLocalizations.of(context);
    return '${l.formatShortDate(d)} ${l.formatTimeOfDay(TimeOfDay.fromDateTime(d), alwaysUse24HourFormat: true)}';
  }

  String state(Json row) => row['state'] == 'PENDING' &&
          row['expiresAt'] <= DateTime.now().millisecondsSinceEpoch
      ? '已到确认期限，请刷新核对'
      : ownershipStates[row['state']]!;
  String who(String id) => id == actor
      ? '${session.displayName}（我）'
      : '账号 ${id.substring(0, id.length.clamp(0, 12))}';
  Future<void> _open(Json row) async {
    if (!available || loading || operation.busy) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = readOwnership(
          await session.api
              .send('GET', '$path/${row['id']}', isCurrent: () => available),
          tenant);
      if (value['id'] != row['id']) {
        throw const ParentApiException(502, 'INVALID_OWNERSHIP_RESPONSE');
      }
      if (available) {
        setState(() {
          selected = value;
          recipient = null;
          choosing = false;
        });
      }
    } catch (e) {
      if (available) setState(() => error = e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _choose() {
    if (!idle || role != 'OWNER') return;
    members ??= PagedCollection(session.api, '/tenants/$tenant/members',
        idField: 'cursor',
        isCurrent: () => available,
        validateItem: validateMemberRow);
    setState(() {
      choosing = true;
      selected = null;
      recipient = null;
      error = null;
    });
  }

  Future<void> _start() async {
    if (!idle || recipient == null || role != 'OWNER') return;
    final target = recipient!;
    if (!await confirm(
        '确认发起交接？',
        '工作空间：$name\n接收账号：${target['actorId']}\n接收人：${memberRoleLabels[target['role']]} → 所有者\n你：所有者 → ${memberRoleLabels[formerRole]}\n\n对方须在 24 小时内通过安全验证并接受，届时才会生效。\n\n$ownershipConsequences',
        '发起，等待对方确认')) return;
    if (!idle) return;
    await operation.submit({
      'operation': 'start',
      'version': tenantVersion,
      'targetActorId': target['actorId']
    });
  }

  Future<void> _act(String action) async {
    final row = selected;
    if (!idle || row == null) return;
    final text = action == 'accept'
        ? '你将成为唯一所有者，原所有者转为${memberRoleLabels[row['formerOwnerRole']]}。\n\n$ownershipConsequences'
        : '此申请将结束，所有者保持不变。';
    final title = action == 'accept'
        ? '接受并成为所有者'
        : action == 'decline'
            ? '拒绝本次交接'
            : '撤销本次交接';
    if (!await confirm(
        title,
        '工作空间：$name\n发起账号：${row['sourceActorId']}\n接收账号：${row['targetActorId']}\n\n$text',
        title)) return;
    if (!idle) return;
    await operation.submit({
      'operation': action,
      'version': row['version'],
      'transferId': row['id']
    });
  }

  Future<void> _retry() async {
    if (await confirm(
        '重试原交接操作？', '将使用原请求编号、原版本和原选择。若权限已变化，请优先查询原结果。', '重试原操作')) {
      await operation.recover(retry: true);
    }
  }

  Future<void> _finish() async {
    if (!available || loading || operation.busy) return;
    if (!operation.committed &&
        !await confirm('已经核对交接记录？', '清除提醒不会撤销或再次执行交接。', '清除提醒')) return;
    if (!await operation.acknowledge() || !available) return;
    setState(() {
      loading = true;
      selected = null;
      recipient = null;
      choosing = false;
    });
    try {
      await session.initialize();
      if (available) {
        if (session.error != null) setState(() => error = session.error);
        await transfers.reload();
      }
    } catch (e) {
      if (available) setState(() => error = e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Widget _message(Object failure) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(ownershipError(failure),
          style: TextStyle(color: Theme.of(context).colorScheme.error)));
  Widget _recovery() => operation.resultTerminal != null
      ? ParentResultTerminalPanel(operation: operation, onViewCurrent: transfers.reload, onEnded: transfers.reload)
      : Card(
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ParentKnownOperationReceipt(operation: operation),
            Text(operation.committed ? '原交接操作已有结果' : '核对上一次交接操作',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (operation.original != null)
              Text('原操作结果：${ownershipStates[operation.original!['state']]}'),
            if (operation.current != null) ...[
              Text('最近核对：${state(operation.current!)}'),
              Text('你的当前角色：${memberRoleLabels[operation.currentRole]}'),
              const Text('交接历史不代表仍为当前所有者，请刷新工作空间权限。')
            ] else
              const Text('尚未核对当前状态。可以查询原结果，也可在下方查看交接记录。'),
            if (operation.error != null) _message(operation.error!),
            OutlinedButton(
                onPressed: operation.busy ? null : () => operation.recover(),
                child: const Text('查询原操作结果')),
            if (!operation.committed && !operation.operationKnownSuccessful)
              OutlinedButton(
                  onPressed: operation.busy ? null : _retry,
                  child: const Text('重试原操作')),
            if (operation.queried)
              FilledButton(
                  onPressed: operation.busy || loading ? null : _finish,
                  child: const Text('完成核对，刷新权限')),
            ExpansionTile(
                title: const Text('操作编号'),
                children: [SelectableText(operation.pending!['requestId'])])
          ])));
  List<Widget> _list() => [
        Text('所有者交接', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(name),
        const SizedBox(height: 8),
        const Text('现任所有者发起，接收人确认后生效。每个工作空间仅允许一份待确认申请，有效期 24 小时。'),
        if (role == 'OWNER') ...[
          const SizedBox(height: 12),
          FilledButton.icon(
              onPressed: idle ? _choose : null,
              icon: const Icon(Icons.person_search_outlined),
              label: const Text('选择接收成员'))
        ],
        if (transfers.loading) const LinearProgressIndicator(),
        if (transfers.error != null) ...[
          _message(transfers.error!),
          TextButton(onPressed: transfers.reload, child: const Text('重新加载交接记录'))
        ],
        if (transfers.loaded && transfers.items.isEmpty)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('暂无交接申请。接收人可在此查看并处理向自己发起的交接。')),
        for (final row in transfers.items)
          Card(
              child: ListTile(
                  onTap: loading || operation.busy ? null : () => _open(row),
                  leading: Icon(row['state'] == 'ACCEPTED'
                      ? Icons.check_circle_outline
                      : Icons.swap_horiz_outlined),
                  title: Text(state(row)),
                  subtitle: Text(
                      '${who(row['sourceActorId'])} → ${who(row['targetActorId'])}\n截止：${date(row['expiresAt'])}'),
                  trailing: const Icon(Icons.chevron_right))),
        if (transfers.hasMore)
          TextButton(
              onPressed: transfers.loadingMore ? null : transfers.loadMore,
              child: Text(transfers.loadingMore ? '正在加载…' : '加载更多交接记录'))
      ];
  List<Widget> _chooser() {
    final m = members!, q = search.text.trim();
    final eligible = m.items.where((r) =>
        r['actorId'] != actor &&
        r['subjectId'] == null &&
        (r['classIds'] as List).isEmpty &&
        const {'GUARDIAN', 'ORG_ADMIN', 'AUDITOR'}.contains(r['role']) &&
        (r['role'] == formerRole || r['role'] == 'AUDITOR'));
    return [
      Text('选择接收成员', style: Theme.of(context).textTheme.headlineSmall),
      const Text('只能选择已加入的成人监护人、机构管理员或审计员。请核对完整账号，避免同名误选。'),
      TextField(
          controller: search,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
              labelText: '查找已加载成员', prefixIcon: Icon(Icons.search))),
      if (m.loading) const LinearProgressIndicator(),
      if (m.error != null) ...[
        _message(m.error!),
        TextButton(onPressed: m.reload, child: const Text('重新加载成员'))
      ],
      for (final row in eligible.where((r) =>
          '${memberName(r)} ${r['actorId']} ${r['verifiedEmail'] ?? ''}'
              .contains(q)))
        Card(
            child: ListTile(
                onTap: idle ? () => setState(() => recipient = row) : null,
                title: Text(memberName(row)),
                subtitle: Text(
                    '${memberRoleLabels[row['role']]}\n${row['verifiedEmail'] ?? row['actorId']}'),
                trailing: const Icon(Icons.chevron_right))),
      if (m.loaded && eligible.isEmpty)
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('已加载成员中没有合适的接收人。可加载后续成员，或返回成员管理先邀请成人加入。')),
      if (m.hasMore)
        TextButton(
            onPressed: m.loadingMore ? null : m.loadMore,
            child: const Text('加载更多成员'))
    ];
  }

  List<Widget> _preview() => [
        Text('核对交接内容', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        Text(name),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(memberName(recipient!),
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      SelectableText('接收账号：${recipient!['actorId']}'),
                      Text('${memberRoleLabels[recipient!['role']]} → 所有者'),
                      const Divider(),
                      Text('你：所有者 → ${memberRoleLabels[formerRole]}')
                    ]))),
        const Text('发起后你仍是所有者，对方须在 24 小时内通过安全验证并接受。你可以在对方接受前撤销。'),
        const SizedBox(height: 16),
        const Text(ownershipConsequences),
        TextButton(
            onPressed: idle ? () => setState(() => recipient = null) : null,
            child: const Text('重新选择接收人'))
      ];
  List<Widget> _detail() {
    final r = selected!;
    final pending = r['state'] == 'PENDING' &&
        r['expiresAt'] > DateTime.now().millisecondsSinceEpoch;
    return [
      Text(state(r), style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      Text(name),
      SelectableText('发起账号：${r['sourceActorId']}\n接收账号：${r['targetActorId']}'),
      const SizedBox(height: 12),
      Text(
          '接收人：${memberRoleLabels[r['targetRole']]} → 所有者\n原所有者：所有者 → ${memberRoleLabels[r['formerOwnerRole']]}'),
      Text('确认截止：${date(r['expiresAt'])}（本机时间）'),
      if (r['reason'] != null)
        Text(switch (r['reason']) {
          'TIME_EXPIRED' => '超过确认期限。',
          'TENANT_CHANGED' => '工作空间已更新，需要重新发起。',
          _ => '成员资格或权限已变化，需要重新发起。'
        }),
      const SizedBox(height: 16),
      const Text(ownershipConsequences),
      const SizedBox(height: 16),
      OutlinedButton(
          onPressed: loading || operation.busy ? null : () => _open(r),
          child: const Text('刷新这份申请')),
      if (pending && actor == r['targetActorId']) ...[
        FilledButton(
            onPressed: idle ? () => _act('accept') : null,
            child: const Text('接受并成为所有者')),
        TextButton(
            onPressed: idle ? () => _act('decline') : null,
            child: const Text('拒绝本次交接'))
      ],
      if (pending && actor == r['sourceActorId'] && role == 'OWNER')
        OutlinedButton(
            onPressed: idle ? () => _act('cancel') : null,
            child: const Text('撤销本次交接')),
      ExpansionTile(title: const Text('交接记录信息'), children: [
        SelectableText(
            '编号：${r['id']}\n记录版本：${r['version']}\n发起时间：${date(r['createdAt'])}')
      ])
    ];
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: Listenable.merge(
          [transfers, operation, if (members != null) members!]),
      builder: (context, _) => Scaffold(
          appBar: AppBar(
              title: const Text('所有者交接'),
              leading: selected != null || choosing
                  ? IconButton(
                      tooltip: '返回交接记录',
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => setState(() {
                            selected = null;
                            recipient = null;
                            choosing = false;
                          }))
                  : null),
          body: !available
              ? const Center(child: Text('交接内容已隐藏。'))
              : RefreshIndicator(
                  onRefresh: transfers.reload,
                  child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(20),
                      children: [
                        if (loading || operation.busy)
                          const LinearProgressIndicator(),
                        if (!operation.loaded) ...[
                          const Text('正在读取本机交接记录。'),
                          if (operation.error != null)
                            _message(operation.error!),
                          TextButton(
                              onPressed: operation.busy ? null : operation.load,
                              child: const Text('重新读取恢复记录'))
                        ],
                        if (operation.pending != null)
                          _recovery()
                        else if (operation.error != null)
                          _message(operation.error!),
                        if (error != null) _message(error!),
                        if (operation.error is ParentApiException &&
                            (operation.error as ParentApiException).code ==
                                'REAUTH_REQUIRED')
                          OutlinedButton(
                              onPressed: operation.busy
                                  ? null
                                  : () => session.signIn(stepUp: true),
                              child: const Text('进行安全验证')),
                        if (selected != null)
                          ..._detail()
                        else if (recipient != null)
                          ..._preview()
                        else if (choosing)
                          ..._chooser()
                        else
                          ..._list()
                      ])),
          bottomNavigationBar:
              available && recipient != null && operation.pending == null
                  ? SafeArea(
                      top: false,
                      child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                          child: FilledButton(
                              onPressed: idle ? _start : null,
                              child: const Text('确认发起交接'))))
                  : null));
}
