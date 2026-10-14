part of 'member_center.dart';

/// Reuses member identity/lifecycle guards and the same paged scope picker.
class InvitationCenter extends StatefulWidget {
  final ParentSession session;
  final InvitationOperationStore? store;
  const InvitationCenter({super.key, required this.session, this.store});
  @override
  State<InvitationCenter> createState() => _InvitationCenterState();
}

class _InvitationCenterState extends State<InvitationCenter>
    with WidgetsBindingObserver, _MemberScope {
  @override
  ParentSession get session => widget.session;
  late final PagedCollection items;
  late final InvitationOperationController operation;
  bool opening = false;
  String? filter;
  @override
  void initState() {
    super.initState();
    items = PagedCollection(session.api, '$root/invitations',
        isCurrent: () => available,
        validateItem: (r) {
          readInvitation(r);
        });
    operation = InvitationOperationController(
        api: session.api,
        tenant: tenant,
        actor: actor,
        store: widget.store ?? InvitationOperationStore(),
        isCurrent: () => available);
    operation.load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) operation.forgetToken();
  }

  @override
  void dispose() {
    items.dispose();
    operation.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (!available || opening || !operation.canSubmit) return;
    setState(() => opening = true);
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) =>
              _InvitationEditor(session: session, operation: operation)));
    } finally {
      if (mounted) setState(() => opening = false);
    }
    if (available) await items.reload();
  }

  Future<void> _cancel(Json row) async {
    if (!available || !operation.canSubmit) return;
    if (!await confirm(
        '取消这份邀请？', '对方尚未使用时，取消会使邀请码失效。若对方已加入，请到成员权限管理。', '确认取消')) {
      return;
    }
    await operation.cancel(row);
    if (available) await items.reload();
  }

  Future<void> _cancelCreated() async {
    final row = operation.latest;
    if (!available ||
        operation.busy ||
        row == null ||
        row['state'] != 'PENDING' ||
        !operation.committed) return;
    if (!await confirm(
        '作废这份邀请？', '未取得邀请码时，可先取消原邀请，再创建新邀请。若对方已接受，取消不会撤销其成员资格。', '确认作废')) {
      return;
    }
    if (await operation.acknowledge()) {
      await operation.cancel(row);
      if (available) await items.reload();
    }
  }

  Future<void> _ack() async {
    if (!operation.committed &&
        !await confirm('已核对邀请记录？', '清除本机提醒不会撤销服务端操作。', '清除提醒')) return;
    if (operation.token != null &&
        !await confirm(
            '已安全传递邀请码？', '关闭后不再展示邀请码。尚未传递时可返回复制；遗失后需要取消邀请再新建。', '完成核对')) return;
    if (await operation.acknowledge()) await items.reload();
  }

  Widget _recovery() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (operation.error != null)
          Text(invitationFailure(operation.error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
                        Text(operation.committed ? '操作已确认' : '核对上一次邀请操作',
                            style: Theme.of(context).textTheme.titleLarge),
                        Text(operation.pending!['operation'] == 'ISSUE'
                            ? '创建邀请'
                            : '取消邀请'),
                        if (operation.pending!['operation'] == 'ISSUE')
                          Text(
                              '收件邮箱：${operation.pending!['input']['recipientEmail']}'),
                        if (operation.latest != null) ...[
                          Text(
                              '最近核对：${invitationStates[operation.latest!['state']]} · ${memberRoleLabels[operation.latest!['role']]}'),
                          Text(
                              '有效期至 ${DateTime.fromMillisecondsSinceEpoch(operation.latest!['expiresAt']).toLocal()}'),
                        ],
                        if (operation.token != null) ...[
                          const SizedBox(height: 12),
                          const Text(
                              '邀请码仅在本次展示。请自行安全传给上述收件人；系统未发送邮件。对方须用该邮箱验证后的账号接受。'),
                          SelectableText(operation.token!,
                              style: Theme.of(context).textTheme.bodyLarge),
                          OutlinedButton.icon(
                              icon: const Icon(Icons.copy),
                              label: const Text('复制邀请码'),
                              onPressed: operation.busy
                                  ? null
                                  : () async {
                                      final token = operation.token;
                                      if (token == null || !available) return;
                                      try {
                                        await Clipboard.setData(
                                            ClipboardData(text: token));
                                        if (mounted && available) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(const SnackBar(
                                                  content:
                                                      Text('邀请码已复制，请仅传给收件人。')));
                                        }
                                      } catch (_) {
                                        if (mounted && available) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(const SnackBar(
                                                  content: Text(
                                                      '复制失败，可选中邀请码手动复制。')));
                                        }
                                      }
                                    }),
                        ] else if (operation.pending!['operation'] == 'ISSUE' &&
                            operation.committed &&
                            operation.latest?['state'] == 'PENDING')
                          const Text(
                              '原邀请已创建，但本机没有邀请码。可直接作废这份邀请后再新建；查询和重试不会重新显示旧邀请码。'),
                        if (operation.pending!['operation'] == 'CANCEL' &&
                            operation.latest?['state'] == 'ACCEPTED')
                          const Text('对方已经加入，取消未生效。如需撤销访问，请到成员权限处理。'),
                        if (operation.queried &&
                            !operation.committed &&
                            operation.latest == null)
                          const Text('未找到可读取的原结果，不代表从未创建。请核对邀请记录。'),
                        ExpansionTile(title: const Text('操作详情'), children: [
                          SelectableText(
                              '请求编号：${operation.pending!['requestId']}'),
                          if (operation.latest != null)
                            SelectableText('邀请编号：${operation.latest!['id']}'),
                        ]),
                        Wrap(spacing: 8, children: [
                          OutlinedButton(
                              onPressed: operation.busy
                                  ? null
                                  : () => operation.recover(),
                              child: const Text('核对原操作')),
                          if (!operation.committed &&
                              operation.latest?['state'] != 'ACCEPTED' &&
                              operation.latest?['state'] != 'EXPIRED')
                            OutlinedButton(
                                onPressed: operation.busy
                                    ? null
                                    : () async {
                                        if (await confirm(
                                            '重试原邀请操作？',
                                            '沿用原内容和请求编号。已创建的邀请不会重复生成，也不会补发旧邀请码。',
                                            '重试原操作')) {
                                          await operation.recover(retry: true);
                                        }
                                      },
                                child: const Text('重试原操作')),
                          if (operation.pending!['operation'] == 'ISSUE' &&
                              operation.committed &&
                              operation.token == null &&
                              operation.latest?['state'] == 'PENDING' &&
                              (operation.latest?['role'] != 'ORG_ADMIN' ||
                                  role == 'OWNER'))
                            OutlinedButton(
                                onPressed:
                                    operation.busy ? null : _cancelCreated,
                                child: const Text('作废这份邀请')),
                          if (operation.queried)
                            FilledButton(
                                onPressed: operation.busy ? null : _ack,
                                child: const Text('完成核对')),
                        ]),
                      ]))),
        if (operation.error is ParentApiException &&
            (operation.error as ParentApiException).code ==
                'REAUTH_REQUIRED') ...[
          const Text('完成验证后重新打开邀请页，原操作仍可恢复。'),
          OutlinedButton(
              onPressed: operation.busy ? null : session.reauthenticate,
              child: const Text('重新安全验证')),
        ],
      ]);
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('成员邀请')),
        body: !available
            ? const Center(child: Text('邀请内容已隐藏。'))
            : AnimatedBuilder(
                animation: Listenable.merge([items, operation]),
                builder: (context, _) {
                  final rows = items.items
                      .where((r) => filter == null || r['state'] == filter)
                      .toList();
                  return RefreshIndicator(
                      onRefresh: items.reload,
                      child: ListView(
                          padding: const EdgeInsets.all(20),
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            Text('邀请合适的人一起管理',
                                style:
                                    Theme.of(context).textTheme.headlineSmall),
                            const SizedBox(height: 8),
                            const Text(
                                '填写收件邮箱、选择职责与范围。邀请有效期为 24 小时；尚未接受前不会获得权限。'),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                                onPressed: opening || !operation.canSubmit
                                    ? null
                                    : _create,
                                icon: const Icon(Icons.person_add_alt_outlined),
                                label: const Text('新建邀请')),
                            if (operation.busy) const LinearProgressIndicator(),
                            _recovery(),
                            const SizedBox(height: 20),
                            DropdownButtonFormField<String>(
                                value: filter ?? 'ALL',
                                isExpanded: true,
                                decoration: const InputDecoration(
                                    labelText: '筛选已加载的邀请'),
                                items: [
                                  const DropdownMenuItem(
                                      value: 'ALL', child: Text('全部状态')),
                                  ...invitationStates.entries.map((e) =>
                                      DropdownMenuItem(
                                          value: e.key, child: Text(e.value)))
                                ],
                                onChanged: (v) => setState(
                                    () => filter = v == 'ALL' ? null : v)),
                            if (items.loading) const LinearProgressIndicator(),
                            if (items.error != null)
                              _MemberError(
                                  error: items.error!, retry: items.reload),
                            if (items.loaded && rows.isEmpty)
                              const Padding(
                                  padding: EdgeInsets.all(20),
                                  child: Text('已加载的邀请中没有匹配项。')),
                            for (final row in rows)
                              Card(
                                  child: ExpansionTile(
                                      leading: const Icon(Icons.mail_outline),
                                      title: Text(
                                          '${memberRoleLabels[row['role']]} · ${invitationStates[row['state']]}'),
                                      subtitle: Text(
                                          '${memberScope(row)} · ${row['id'].substring(0, 8)}'),
                                      children: [
                                    ListTile(
                                        title: const Text('有效期至'),
                                        subtitle: Text(
                                            '${DateTime.fromMillisecondsSinceEpoch(row['expiresAt']).toLocal()}')),
                                    Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: SelectableText(
                                            '邀请编号：${row['id']}')),
                                    if (row['state'] == 'PENDING' &&
                                        (row['role'] != 'ORG_ADMIN' ||
                                            role == 'OWNER'))
                                      TextButton(
                                          onPressed: !operation.canSubmit
                                              ? null
                                              : () => _cancel(row),
                                          child: const Text('取消邀请')),
                                  ])),
                            if (items.hasMore)
                              OutlinedButton(
                                  onPressed:
                                      items.loadingMore ? null : items.loadMore,
                                  child: const Text('加载更多邀请')),
                          ]));
                }),
      );
}

class _InvitationEditor extends StatefulWidget {
  final ParentSession session;
  final InvitationOperationController operation;
  const _InvitationEditor({required this.session, required this.operation});
  @override
  State<_InvitationEditor> createState() => _InvitationEditorState();
}

class _InvitationEditorState extends State<_InvitationEditor>
    with WidgetsBindingObserver, _MemberScope {
  @override
  ParentSession get session => widget.session;
  final email = TextEditingController();
  late String selectedRole;
  bool byClass = false, picking = false;
  Json? subject;
  final classes = <Json>[];
  String? validation;
  @override
  void initState() {
    super.initState();
    selectedRole = kind == 'FAMILY' ? 'GUARDIAN' : 'TEACHER';
  }

  @override
  void dispose() {
    email.clear();
    email.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    if (!available || picking) return;
    setState(() => picking = true);
    try {
      final rows = await Navigator.of(context).push<List<Json>>(
          MaterialPageRoute(
              builder: (_) => _MemberScopePicker(
                  session: session,
                  byClass: byClass && selectedRole == 'TEACHER',
                  initial: classes)));
      if (available && rows != null) {
        setState(() {
          if (byClass && selectedRole == 'TEACHER') {
            classes.clear();
            classes.addAll(rows);
          } else {
            subject = rows.single;
          }
          validation = null;
        });
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> _issue() async {
    if (!available || picking || !widget.operation.canSubmit) return;
    final scoped = const {'TEACHER', 'CHILD'}.contains(selectedRole),
        multi = selectedRole == 'TEACHER' && byClass;
    final input = <String, dynamic>{
      'recipientEmail': email.text.trim(),
      'role': selectedRole,
      'subjectId': scoped && !multi ? (subject?['id']) : null,
      'classIds': multi ? classes.map((r) => r['id']).toList() : <String>[]
    };
    try {
      validateInvitationInput(input);
    } catch (_) {
      setState(() => validation = '请填写有效邮箱，并选择该角色需要的学生或班级。');
      return;
    }
    if (!await confirm(
        '创建成员邀请？',
        '收件邮箱：${input['recipientEmail']}\n职责：${memberRoleLabels[selectedRole]}\n'
            '范围：${multi ? classes.map((r) => r['name']).join('、') : scoped ? subject!['nickname'] : '工作空间'}\n'
            '有效期 24 小时，接受后按上述范围访问。系统不会自动发送邮件。',
        '确认创建')) return;
    await widget.operation.issue(input);
    if (mounted && available && widget.operation.pending != null) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('新建成员邀请')),
        bottomNavigationBar: !available
            ? null
            : AnimatedBuilder(
                animation: widget.operation,
                builder: (context, _) => SafeArea(
                    child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                        child: FilledButton(
                            onPressed: picking || !widget.operation.canSubmit
                                ? null
                                : _issue,
                            child: const Text('核对并创建'))))),
        body: !available
            ? const Center(child: Text('邀请内容已隐藏。'))
            : AnimatedBuilder(
                animation: widget.operation,
                builder: (context, _) =>
                    ListView(padding: const EdgeInsets.all(20), children: [
                      const Text('收件人使用已验证的同一邮箱接受邀请后，才会加入当前家庭或机构。'),
                      const SizedBox(height: 16),
                      TextField(
                          controller: email,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          enableSuggestions: false,
                          maxLength: 254,
                          decoration: const InputDecoration(
                              labelText: '收件邮箱',
                              prefixIcon: Icon(Icons.alternate_email)),
                          enabled: !widget.operation.busy),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                          value: selectedRole,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: '职责角色'),
                          items: invitationRoles(kind, role)
                              .map((r) => DropdownMenuItem(
                                  value: r, child: Text(memberRoleLabels[r]!)))
                              .toList(),
                          onChanged: picking || widget.operation.busy
                              ? null
                              : (r) => setState(() {
                                    if (r == selectedRole) return;
                                    selectedRole = r!;
                                    byClass = false;
                                    subject = null;
                                    classes.clear();
                                    validation = null;
                                  })),
                      const SizedBox(height: 8),
                      Text(memberRoleDescription(selectedRole)),
                      if (selectedRole == 'TEACHER')
                        SwitchListTile(
                            title: const Text('按班级授权'),
                            subtitle: const Text('最多 50 个班级；关闭后选择单个学生'),
                            value: byClass,
                            onChanged: picking || widget.operation.busy
                                ? null
                                : (v) => setState(() {
                                      byClass = v;
                                      subject = null;
                                      classes.clear();
                                      validation = null;
                                    })),
                      if (const {'TEACHER', 'CHILD'}
                          .contains(selectedRole)) ...[
                        if (byClass && selectedRole == 'TEACHER') ...[
                          for (final row in classes)
                            ListTile(
                                title: Text(row['name']),
                                trailing: IconButton(
                                    tooltip: '移除 ${row['name']}',
                                    icon:
                                        const Icon(Icons.remove_circle_outline),
                                    onPressed: widget.operation.busy
                                        ? null
                                        : () => setState(
                                            () => classes.remove(row)))),
                        ] else if (subject != null)
                          ListTile(
                              title: Text(subject!['nickname']),
                              subtitle: const Text('已选学生')),
                        OutlinedButton.icon(
                            onPressed:
                                picking || widget.operation.busy ? null : _pick,
                            icon: const Icon(Icons.search),
                            label: Text(byClass && selectedRole == 'TEACHER'
                                ? '选择班级（${classes.length}/50）'
                                : '选择学生档案')),
                      ],
                      if (validation != null)
                        Text(validation!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      if (widget.operation.error != null)
                        Text(invitationFailure(widget.operation.error!),
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      if (!widget.operation.loaded && !widget.operation.busy)
                        OutlinedButton(
                            onPressed: widget.operation.load,
                            child: const Text('重新读取恢复记录')),
                      const SizedBox(height: 20),
                      const Text(
                          '邀请码只在创建成功后展示。请安全传给收件人；离开应用或关闭结果后，需要取消旧邀请再新建才能取得新码。'),
                    ])),
      );
}
