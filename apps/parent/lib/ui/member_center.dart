import 'operation_result_terminal_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/invitations.dart';
import '../core/member_access.dart';
import '../core/organization_classes.dart' show readSchoolClass;
import '../core/paged_collection.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import 'ownership_center.dart';

part 'invitation_center.dart';

mixin _MemberScope<T extends StatefulWidget> on State<T>
    implements WidgetsBindingObserver {
  ParentSession get session;
  late final String tenant, actor, role, kind;
  late final int generation;
  bool foreground = true;
  Route<dynamic>? dialog;
  bool get current =>
      mounted &&
      !_operationOwnerLost &&
      session.authenticated &&
      session.tenant?['id'] == tenant &&
      session.profile?['subject'] == actor &&
      session.role == role &&
      session.generation == generation &&
      const {'OWNER', 'ORG_ADMIN'}.contains(role);
  bool get available => current && foreground;
  String get root => '/tenants/$tenant';
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
    kind = session.tenant!['kind'];
    actor = session.profile!['subject'];
    role = session.role;
    generation = session.generation;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    session.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
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
    if (!foreground && dialog?.isActive == true) {
      dialog!.navigator?.removeRoute(dialog!);
    }
    if (mounted) setState(() {});
  }

  Future<bool> confirm(String title, String text, String action) async {
    if (!available) return false;
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
      return await Navigator.of(context).push(route) == true && available;
    } finally {
      if (identical(dialog, route)) dialog = null;
    }
  }

  @override
  void dispose() {
    session.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class MemberCenter extends StatefulWidget {
  final ParentSession session;
  final MemberOperationStore? store;
  const MemberCenter({super.key, required this.session, this.store});
  @override
  State<MemberCenter> createState() => _MemberCenterState();
}

class _MemberCenterState extends State<MemberCenter>
    with WidgetsBindingObserver, _MemberScope {
  @override
  ParentSession get session => widget.session;
  late final PagedCollection members;
  late final MemberOperationController operation;
  final search = TextEditingController();
  bool opening = false;
  @override
  void initState() {
    super.initState();
    members = PagedCollection(session.api, '$root/members',
        idField: 'cursor',
        isCurrent: () => available,
        validateItem: validateMemberRow);
    operation = MemberOperationController(
        api: session.api,
        tenant: tenant,
        actor: actor,
        store: widget.store ?? MemberOperationStore(),
        isCurrent: () => available);
    operation.load();
  }

  Future<void> _open(Json row) async {
    if (!available || opening || operation.busy) return;
    setState(() => opening = true);
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) =>
              _MemberDetail(session: session, operation: operation, row: row)));
    } finally {
      if (mounted) setState(() => opening = false);
    }
    if (available) await members.reload();
  }

  @override
  void dispose() {
    members.dispose();
    operation.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('成员与权限')),
      body: !available
          ? const Center(child: Text('成员内容已隐藏。'))
          : AnimatedBuilder(
              animation: Listenable.merge([members, operation]),
              builder: (context, _) {
                final rows = members.items
                    .where((r) =>
                        '${memberName(r)} ${memberRoleLabels[r['role']]}'
                            .contains(search.text.trim()))
                    .toList();
                return RefreshIndicator(
                    onRefresh: members.reload,
                    child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(20),
                        children: [
                          Text('让每个人只访问所需内容',
                              style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 8),
                          const Text('选择成员，查看职责和访问范围，再调整权限。所有者变更由双方确认后生效。'),
                          OwnershipEntry(session: session),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                              onPressed: opening
                                  ? null
                                  : () async {
                                      if (!available) return;
                                      setState(() => opening = true);
                                      try {
                                        await Navigator.of(context).push(
                                            MaterialPageRoute<void>(
                                                builder: (_) =>
                                                    InvitationCenter(
                                                        session: session)));
                                      } finally {
                                        if (mounted) {
                                          setState(() => opening = false);
                                        }
                                      }
                                      if (available) await members.reload();
                                    },
                              icon: const Icon(Icons.person_add_alt_outlined),
                              label: const Text('邀请成员与记录')),
                          _MemberRecovery(
                              session: session,
                              operation: operation,
                              confirm: confirm,
                              onCleared: members.reload),
                          const SizedBox(height: 16),
                          TextField(
                              controller: search,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                  labelText: '查找已加载的成员或角色',
                                  prefixIcon: Icon(Icons.search))),
                          if (members.loading) const LinearProgressIndicator(),
                          if (members.error != null)
                            _MemberError(
                                error: members.error!, retry: members.reload),
                          if (members.loaded && rows.isEmpty)
                            const Padding(
                                padding: EdgeInsets.all(24),
                                child: Text('已加载的成员中没有匹配项。')),
                          for (final m in rows)
                            Card(
                                child: ListTile(
                                    leading: const Icon(Icons.person_outline),
                                    title: Text(
                                        '${memberName(m)}${m['actorId'] == actor ? '（我）' : ''}'),
                                    subtitle: Text(
                                        '${memberRoleLabels[m['role']]} · ${memberScope(m)}'),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: opening ? null : () => _open(m))),
                          if (members.hasMore)
                            OutlinedButton(
                                onPressed: members.loadingMore
                                    ? null
                                    : members.loadMore,
                                child: const Text('加载更多成员')),
                        ]));
              }));
}

class _MemberRecovery extends StatelessWidget {
  final ParentSession session;
  final MemberOperationController operation;
  final Future<bool> Function(String, String, String) confirm;
  final Future<void> Function() onCleared;
  final Future<void> Function()? onViewCurrent;
  const _MemberRecovery(
      {required this.session,
      required this.operation,
      required this.confirm,
      required this.onCleared, this.onViewCurrent});
  @override
  Widget build(BuildContext context) => operation.resultTerminal != null
      ? ParentResultTerminalPanel(operation: operation, onViewCurrent: onViewCurrent ?? onCleared, onEnded: onCleared)
      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ParentKnownOperationReceipt(operation: operation),
        if (operation.busy) const LinearProgressIndicator(),
        if (operation.error != null)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(memberFailure(operation.error!),
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
        if (!operation.loaded && !operation.busy)
          OutlinedButton(
              onPressed: operation.load, child: const Text('重新读取恢复记录')),
        if (operation.pending != null)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(operation.saved ? '原操作已保存' : '核对上一次成员操作',
                            style: Theme.of(context).textTheme.titleLarge),
                        Text(
                            operation.pending!['input']['operation'] == 'REVOKE'
                                ? '撤销成员资格'
                                : '调整角色或访问范围'),
                        if (operation.committed != null)
                          Text(
                              '原结果：${memberRoleLabels[operation.committed!['role']]} · ${memberScope(operation.committed!)}（历史快照）'),
                        if (operation.latest != null)
                          Text(
                              '最近核对：${operation.currentState == 'REVOKED' ? '已撤销' : '仍为有效成员'} · ${memberRoleLabels[operation.latest!['role']]}'),
                        if (operation.saved &&
                            operation.pending!['input']['operation'] ==
                                'REVOKE' &&
                            operation.currentState == 'ACTIVE')
                          const Text(
                              '原撤销已提交，但该账号后来又成为有效成员。请核对最新授权，不要把历史撤销当作当前状态。'),
                        if (operation.queried && !operation.saved)
                          const Text('未找到可读取的原结果，不代表从未提交。请核对成员与变更历史。'),
                        ExpansionTile(title: const Text('操作详情'), children: [
                          SelectableText(
                              '请求编号：${operation.pending!['requestId']}')
                        ]),
                        Wrap(spacing: 8, children: [
                          OutlinedButton(
                              onPressed: operation.busy
                                  ? null
                                  : () => operation.recover(),
                              child: const Text('核对原操作')),
                          if (!operation.saved && !operation.operationKnownSuccessful)
                            OutlinedButton(
                                onPressed: operation.busy
                                    ? null
                                    : () async {
                                        if (await confirm(
                                            '重试原权限操作？',
                                            '保留原内容、请求编号和成员版本，不会自动覆盖更新后的权限。',
                                            '重试原操作')) {
                                          await operation.recover(retry: true);
                                        }
                                      },
                                child: const Text('重试原操作')),
                          if (operation.queried)
                            FilledButton(
                                onPressed: operation.busy
                                    ? null
                                    : () async {
                                        final owner = ModalRoute.of(context);
                                        bool active() => context.mounted && operation.operationCurrent &&
                                            owner?.isActive == true && owner?.isCurrent == true;
                                        if (!active()) return;
                                        if (!operation.saved &&
                                            !await parentOperationConfirmation(context,
                                                operation: operation, accessChanges: session,
                                                isCurrent: () => operation.operationCurrent,
                                                title: '已核对成员和历史？',
                                                description: '清除本机提醒不会撤销服务端操作。',
                                                confirmLabel: '清除提醒')) return;
                                        if (!active()) return;
                                        if (await operation.acknowledge() && active()) {
                                          await onCleared();
                                        }
                                      },
                                child: Text(
                                    operation.saved ? '完成核对' : '已核对，清除提醒')),
                        ]),
                        if (operation.error is ParentApiException &&
                            (operation.error as ParentApiException).code ==
                                'REAUTH_REQUIRED') ...[
                          const Text('完成验证后重新打开成员页，可核对或重试原操作。'),
                          OutlinedButton(
                              onPressed: operation.busy
                                  ? null
                                  : session.reauthenticate,
                              child: const Text('重新安全验证')),
                        ],
                      ]))),
      ]);
}

class _MemberDetail extends StatefulWidget {
  final ParentSession session;
  final MemberOperationController operation;
  final Json row;
  const _MemberDetail(
      {required this.session, required this.operation, required this.row});
  @override
  State<_MemberDetail> createState() => _MemberDetailState();
}

class _MemberDetailState extends State<_MemberDetail>
    with WidgetsBindingObserver, _MemberScope {
  @override
  ParentSession get session => widget.session;
  Json? member;
  Object? error;
  bool reading = false, opening = false;
  late final PagedCollection history;
  String get path => '$root/members/${widget.row['cursor']}';
  @override
  void initState() {
    super.initState();
    history = PagedCollection(session.api, '$path/access-history',
        isCurrent: () => available, validateItem: validateMemberHistory);
    _reload();
  }

  Future<void> _reload() async {
    if (!available || reading) return;
    setState(() {
      reading = true;
      error = null;
      member = null;
    });
    try {
      final row = readMemberAccess(
          await session.api.object('$path/access', isCurrent: () => available));
      if (row['memberKey'] != widget.row['cursor'] ||
          row['actorId'] != widget.row['actorId']) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (available) setState(() => member = row);
    } catch (failure) {
      if (available) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => reading = false);
    }
    if (available) await history.reload();
  }

  Future<void> _edit() async {
    if (!available ||
        opening ||
        member == null ||
        !widget.operation.canSubmit) {
      return;
    }
    setState(() => opening = true);
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => _MemberEditor(
              session: session,
              operation: widget.operation,
              before: member!,
              name: memberName(widget.row))));
    } finally {
      if (mounted) setState(() => opening = false);
    }
    if (available) await _reload();
  }

  Future<void> _revoke() async {
    final before = member!;
    if (!await confirm(
        '撤销 ${memberName(widget.row)} 的成员资格？',
        '该账号将失去当前工作空间访问资格。\n$memberConsequences\n这不会删除儿童档案、设备或关闭账号。',
        '确认撤销')) return;
    await widget.operation
        .submit({'operation': 'REVOKE', 'version': before['version']}, before);
  }

  @override
  void dispose() {
    history.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('成员权限'), actions: [
        IconButton(
            tooltip: '刷新权限和历史',
            onPressed: !available || reading ? null : _reload,
            icon: const Icon(Icons.refresh))
      ]),
      body: !available
          ? const Center(child: Text('成员内容已隐藏。'))
          : AnimatedBuilder(
              animation: Listenable.merge([history, widget.operation]),
              builder: (context, _) =>
                  ListView(padding: const EdgeInsets.all(20), children: [
                    _MemberRecovery(
                        session: session,
                        operation: widget.operation,
                        confirm: confirm,
                        onViewCurrent: () async {
                          final route = ModalRoute.of(context);
                          if (available && route?.isCurrent == true) Navigator.pop(context);
                        },
                        onCleared: () async {
                          final owner = ModalRoute.of(context);
                          if (available && widget.operation.pending == null &&
                              owner?.isActive == true && owner?.isCurrent == true) {
                            owner!.navigator?.pop();
                          }
                        }),
                    Text(memberName(widget.row),
                        style: Theme.of(context).textTheme.headlineSmall),
                    if (widget.row['verifiedEmail'] != null)
                      Text(widget.row['verifiedEmail']),
                    ExpansionTile(
                        title: const Text('核对账号身份'),
                        children: [SelectableText(widget.row['actorId'])]),
                    if (reading) const LinearProgressIndicator(),
                    if (error != null)
                      _MemberError(error: error!, retry: _reload),
                    if (member != null) ...[
                      Text(memberRoleLabels[member!['role']]!,
                          style: Theme.of(context).textTheme.titleLarge),
                      Text(memberRoleDescription(member!['role'])),
                      ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.account_tree_outlined),
                          title: const Text('访问范围'),
                          subtitle: Text(memberScope(member!))),
                      if (memberRoles(kind, role, member!['role']).isNotEmpty)
                        Wrap(spacing: 8, children: [
                          FilledButton.icon(
                              onPressed: opening || !widget.operation.canSubmit
                                  ? null
                                  : _edit,
                              icon: const Icon(Icons.edit_outlined),
                              label: const Text('调整角色与范围')),
                          TextButton(
                              onPressed: opening || !widget.operation.canSubmit
                                  ? null
                                  : _revoke,
                              child: const Text('撤销成员资格')),
                        ])
                      else
                        const Text('当前角色不能调整此成员；所有者变更需专门交接。'),
                    ],
                    const SizedBox(height: 20),
                    Text('权限变更记录',
                        style: Theme.of(context).textTheme.titleLarge),
                    if (history.loading) const LinearProgressIndicator(),
                    if (history.error != null)
                      _MemberError(
                          error: history.error!, retry: history.reload),
                    if (history.loaded && history.items.isEmpty)
                      const Text('暂无权限调整记录。加入和邀请记录不在此列表中。'),
                    for (final h in history.items)
                      ExpansionTile(
                          title: Text(h['changeType'] == 'REVOKED'
                              ? '撤销成员资格'
                              : '${memberRoleLabels[h['previousRole']]} → ${memberRoleLabels[h['role']]}'),
                          subtitle: Text(
                              '${DateTime.fromMillisecondsSinceEpoch(h['occurredAt']).toLocal()} · 版本 ${h['memberVersion']}'),
                          children: [
                            ListTile(
                                title: const Text('变更前范围'),
                                subtitle: Text(memberScope({
                                  'role': h['previousRole'],
                                  'subjectId': h['previousSubjectId'],
                                  'classIds': h['previousClassIds']
                                }))),
                            ListTile(
                                title: const Text('变更后范围'),
                                subtitle: Text(h['changeType'] == 'REVOKED'
                                    ? '已撤销资格'
                                    : memberScope(h))),
                            ExpansionTile(title: const Text('审计详情'), children: [
                              SelectableText('操作者账号：${h['changedByActorId']}\n'
                                  '原档案：${h['previousSubjectId'] ?? '无'}\n原班级：${(h['previousClassIds'] as List).join('、')}\n'
                                  '新档案：${h['subjectId'] ?? '无'}\n新班级：${(h['classIds'] as List).join('、')}')
                            ])
                          ]),
                    if (history.hasMore)
                      OutlinedButton(
                          onPressed:
                              history.loadingMore ? null : history.loadMore,
                          child: const Text('加载更早记录')),
                  ])));
}

class _MemberEditor extends StatefulWidget {
  final ParentSession session;
  final MemberOperationController operation;
  final Json before;
  final String name;
  const _MemberEditor(
      {required this.session,
      required this.operation,
      required this.before,
      required this.name});
  @override
  State<_MemberEditor> createState() => _MemberEditorState();
}

class _MemberEditorState extends State<_MemberEditor>
    with WidgetsBindingObserver, _MemberScope {
  @override
  ParentSession get session => widget.session;
  late String selectedRole;
  bool byClass = false, reading = false, picking = false;
  Json? subject;
  final classes = <Json>[];
  Object? error;
  String? validationError;
  @override
  void initState() {
    super.initState();
    selectedRole = widget.before['role'];
    byClass = (widget.before['classIds'] as List).isNotEmpty;
    _resolve();
  }

  Future<void> _resolve() async {
    if (!available || reading) return;
    setState(() {
      reading = true;
      error = null;
      validationError = null;
    });
    try {
      Json? nextSubject;
      final nextClasses = <Json>[];
      if (widget.before['subjectId'] != null) {
        nextSubject = await _readSelection(widget.before['subjectId'], true);
      }
      // At most 50 configured classes; bounded batches avoid an unbounded directory fetch.
      final ids = (widget.before['classIds'] as List).cast<String>();
      for (var i = 0; i < ids.length; i += 5) {
        if (!available) return;
        nextClasses.addAll(await Future.wait(
            ids.skip(i).take(5).map((id) => _readSelection(id, false))));
      }
      if (available) {
        setState(() {
          subject = nextSubject;
          classes.clear();
          classes.addAll(nextClasses);
        });
      }
    } catch (failure) {
      if (available) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => reading = false);
    }
  }

  Future<Json> _readSelection(String id, bool student) async {
    try {
      final row = await session.api.object(
          '$root/${student ? 'subjects' : 'classes'}/$id',
          isCurrent: () => available);
      _validateSelection(row, student);
      if (row['id'] != id) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      return row;
    } on ParentApiException catch (e) {
      if (e.status == 403 || e.status == 404) {
        return {
          'id': id,
          student ? 'nickname' : 'name': '当前不可用',
          'state': 'UNAVAILABLE'
        };
      }
      rethrow;
    }
  }

  Future<void> _pick() async {
    if (!available || picking || reading) return;
    setState(() => picking = true);
    try {
      final rows = await Navigator.of(context).push<List<Json>>(
          MaterialPageRoute(
              builder: (_) => _MemberScopePicker(
                  session: session,
                  byClass: selectedRole == 'TEACHER' && byClass,
                  initial: classes)));
      if (available && rows != null) {
        setState(() {
          if (selectedRole == 'TEACHER' && byClass) {
            classes.clear();
            classes.addAll(rows);
          } else {
            subject = rows.single;
          }
          error = null;
          validationError = null;
        });
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> _save() async {
    if (!available ||
        reading ||
        picking ||
        error != null ||
        !widget.operation.canSubmit) return;
    final needsScope = selectedRole == 'TEACHER' || selectedRole == 'CHILD',
        useClasses = selectedRole == 'TEACHER' && byClass;
    if (needsScope &&
        (useClasses
            ? classes.isEmpty || classes.any((r) => r['state'] != 'ACTIVE')
            : subject == null || subject!['state'] == 'UNAVAILABLE')) {
      setState(() => validationError = '请选择有效学生或班级；移除已归档和不可用的范围。');
      return;
    }
    final Json input = {
      'operation': 'UPDATE',
      'version': widget.before['version'],
      'role': selectedRole,
      'subjectId': needsScope && !useClasses ? subject!['id'] : null,
      'classIds': useClasses ? classes.map((r) => r['id']).toList() : <String>[]
    };
    if (!await confirm(
        '调整 ${widget.name} 的权限？',
        '${memberRoleLabels[selectedRole]}\n'
            '${useClasses ? classes.map((r) => r['name']).join('、') : needsScope ? subject!['nickname'] : '工作空间范围'}\n$memberConsequences',
        '确认保存')) return;
    await widget.operation.submit(input, widget.before);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('调整成员权限')),
      // Keep the primary action reachable with large fonts and long class selections.
      bottomNavigationBar: !available
          ? null
          : AnimatedBuilder(
              animation: widget.operation,
              builder: (context, _) => widget.operation.pending != null
                  ? const SizedBox.shrink()
                  : SafeArea(
                      child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                          child: FilledButton(
                              onPressed: reading ||
                                      picking ||
                                      error != null ||
                                      !widget.operation.canSubmit
                                  ? null
                                  : _save,
                              child: const Text('核对并保存'))))),
      body: !available
          ? const Center(child: Text('权限内容已隐藏。'))
          : AnimatedBuilder(
              animation: widget.operation,
              builder: (context, _) =>
                  ListView(padding: const EdgeInsets.all(20), children: [
                    _MemberRecovery(
                        session: session,
                        operation: widget.operation,
                        confirm: confirm,
                        onCleared: () async {
                          final owner = ModalRoute.of(context);
                          if (available && owner?.isActive == true && owner?.isCurrent == true) {
                            owner!.navigator?.pop();
                          }
                        }),
                    if (widget.operation.pending == null) ...[
                      Text(widget.name,
                          style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                          value: selectedRole,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: '职责角色'),
                          items: memberRoles(kind, role, widget.before['role'])
                              .map((r) => DropdownMenuItem(
                                  value: r, child: Text(memberRoleLabels[r]!)))
                              .toList(),
                          onChanged: reading || picking || widget.operation.busy
                              ? null
                              : (r) => setState(() {
                                    if (r == selectedRole) return;
                                    selectedRole = r!;
                                    subject = null;
                                    classes.clear();
                                    byClass = false;
                                    error = null;
                                    validationError = null;
                                  })),
                      const SizedBox(height: 8),
                      Text(memberRoleDescription(selectedRole)),
                      if (selectedRole == 'TEACHER')
                        SwitchListTile(
                            title: const Text('按班级授权'),
                            subtitle: const Text('最多 50 个班级；关闭后选择单个学生'),
                            value: byClass,
                            onChanged:
                                reading || picking || widget.operation.busy
                                    ? null
                                    : (v) => setState(() {
                                          byClass = v;
                                          subject = null;
                                          classes.clear();
                                          error = null;
                                          validationError = null;
                                        })),
                      if (selectedRole == 'TEACHER' ||
                          selectedRole == 'CHILD') ...[
                        if (byClass && selectedRole == 'TEACHER') ...[
                          for (final c in classes)
                            ListTile(
                                title: Text(c['name']),
                                subtitle: Text(c['state'] == 'ACTIVE'
                                    ? '当前已选班级'
                                    : '已归档或不可用，请移除'),
                                trailing: IconButton(
                                    tooltip: '移除 ${c['name']}',
                                    onPressed: reading || widget.operation.busy
                                        ? null
                                        : () => setState(() {
                                              classes.remove(c);
                                              error = null;
                                              validationError = null;
                                            }),
                                    icon: const Icon(
                                        Icons.remove_circle_outline))),
                        ] else if (subject != null)
                          ListTile(
                              title: Text(subject!['nickname']),
                              subtitle: Text(subject!['state'] == 'UNAVAILABLE'
                                  ? '档案不可用，请重新选择'
                                  : '当前已选学生')),
                        OutlinedButton.icon(
                            onPressed:
                                reading || picking || widget.operation.busy
                                    ? null
                                    : _pick,
                            icon: const Icon(Icons.search),
                            label: Text(byClass && selectedRole == 'TEACHER'
                                ? '选择班级（${classes.length}/50）'
                                : '选择学生档案')),
                      ],
                      if (reading) const LinearProgressIndicator(),
                      if (error != null)
                        _MemberError(error: error!, retry: _resolve),
                      if (validationError != null)
                        Text(validationError!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      const SizedBox(height: 20),
                      const Text(memberConsequences),
                    ],
                  ])));
}

void _validateSelection(Json row, bool subject) {
  if (!subject) {
    readSchoolClass(row);
    return;
  }
  if (row['id'] is! String ||
      !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          .hasMatch(row['id']) ||
      row['nickname'] is! String ||
      row['nickname'].trim().isEmpty ||
      row['nickname'].length > 100) {
    throw const ParentApiException(502, 'INVALID_RESPONSE');
  }
}

class _MemberScopePicker extends StatefulWidget {
  final ParentSession session;
  final bool byClass;
  final List<Json> initial;
  const _MemberScopePicker(
      {required this.session, required this.byClass, required this.initial});
  @override
  State<_MemberScopePicker> createState() => _MemberScopePickerState();
}

class _MemberScopePickerState extends State<_MemberScopePicker>
    with WidgetsBindingObserver, _MemberScope {
  @override
  ParentSession get session => widget.session;
  late final PagedCollection items;
  final selected = <String, Json>{};
  final search = TextEditingController();
  @override
  void initState() {
    super.initState();
    if (widget.byClass) {
      for (final c in widget.initial) {
        selected[c['id']] = c;
      }
    }
    items = PagedCollection(
        session.api, '$root/${widget.byClass ? 'classes' : 'subjects'}',
        isCurrent: () => available,
        validateItem: (row) => _validateSelection(row, !widget.byClass));
  }

  @override
  void dispose() {
    items.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(widget.byClass ? '选择授权班级' : '选择学生档案')),
      bottomNavigationBar: !available || !widget.byClass
          ? null
          : SafeArea(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton(
                      onPressed: selected.isEmpty ||
                              selected.values.any((r) => r['state'] != 'ACTIVE')
                          ? null
                          : () =>
                              Navigator.pop(context, selected.values.toList()),
                      child: Text('确认 ${selected.length} 个班级')))),
      body: !available
          ? const Center(child: Text('目录已隐藏。'))
          : AnimatedBuilder(
              animation: items,
              builder: (context, _) {
                final rows = items.items
                    .where((r) =>
                        (r[widget.byClass ? 'name' : 'nickname'] as String)
                            .contains(search.text.trim()))
                    .toList();
                return ListView.builder(
                    padding: const EdgeInsets.all(20),
                    itemCount: rows.length + 2,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextField(
                                  controller: search,
                                  onChanged: (_) => setState(() {}),
                                  decoration: const InputDecoration(
                                      labelText: '查找已加载记录',
                                      prefixIcon: Icon(Icons.search))),
                              if (widget.byClass && selected.isNotEmpty)
                                Wrap(
                                    spacing: 6,
                                    children: selected.values
                                        .map((c) => InputChip(
                                            label: Text(c['name']),
                                            onDeleted: () => setState(() =>
                                                selected.remove(c['id']))))
                                        .toList()),
                              if (items.loading)
                                const LinearProgressIndicator(),
                              if (items.error != null)
                                _MemberError(
                                    error: items.error!, retry: items.reload),
                              if (items.loaded && rows.isEmpty)
                                const Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Text('没有可选记录，可先创建学生或班级。')),
                            ]);
                      }
                      if (index == rows.length + 1) {
                        return items.hasMore
                            ? OutlinedButton(
                                onPressed:
                                    items.loadingMore ? null : items.loadMore,
                                child: const Text('加载更多'))
                            : const SizedBox.shrink();
                      }
                      final row = rows[index - 1];
                      if (!widget.byClass) {
                        return ListTile(
                            title: Text(row['nickname']),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () {
                              if (available) Navigator.pop(context, [row]);
                            });
                      }
                      final checked = selected.containsKey(row['id']);
                      return CheckboxListTile(
                          title: Text(row['name']),
                          subtitle: Text('${row['studentCount']} 个学生关联'),
                          value: checked,
                          onChanged: row['state'] != 'ACTIVE' ||
                                  (!checked && selected.length >= 50)
                              ? null
                              : (v) => setState(() {
                                    if (v == true) {
                                      selected[row['id']] = row;
                                    } else {
                                      selected.remove(row['id']);
                                    }
                                  }));
                    });
              }));
}

class _MemberError extends StatelessWidget {
  final Object error;
  final Future<void> Function() retry;
  const _MemberError({required this.error, required this.retry});
  @override
  Widget build(BuildContext context) => Column(children: [
        Text(memberFailure(error)),
        TextButton(onPressed: retry, child: const Text('重新读取'))
      ]);
}
