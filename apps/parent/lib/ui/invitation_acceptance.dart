import 'package:flutter/material.dart';
import '../core/invitation_acceptance.dart';
import '../core/member_access.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';

/// Available to signed-in recipients even before they have their first workspace.
class InvitationAcceptanceEntry extends StatelessWidget {
  final ParentSession session;
  const InvitationAcceptanceEntry({super.key, required this.session});
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
      onPressed: session.authenticated && !session.busy
          ? () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => InvitationAcceptancePage(session: session)))
          : null,
      icon: const Icon(Icons.group_add_outlined),
      label: const Text('使用邀请码加入'));
}

class InvitationJoinLanding extends StatelessWidget {
  final ParentSession session;
  final Widget child;
  const InvitationJoinLanding(
      {super.key, required this.session, required this.child});
  @override
  Widget build(BuildContext context) => Column(children: [
        Expanded(child: child),
        SafeArea(
            top: false,
            child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: SizedBox(
                    width: double.infinity,
                    child: InvitationAcceptanceEntry(session: session))))
      ]);
}

class InvitationAcceptancePage extends StatefulWidget {
  final ParentSession session;
  final InvitationAcceptanceStore? store;
  const InvitationAcceptancePage(
      {super.key, required this.session, this.store});
  @override
  State<InvitationAcceptancePage> createState() =>
      _InvitationAcceptancePageState();
}

class _InvitationAcceptancePageState extends State<InvitationAcceptancePage>
    with WidgetsBindingObserver {
  final tokenInput = TextEditingController();
  late final String actor;
  late final int generation;
  late final InvitationAcceptanceController operation;
  Route<dynamic>? dialog;
  bool foreground = true, refreshing = false;
  Object? refreshError;
  ParentSession get session => widget.session;
  bool get identityMatches =>
      session.authenticated &&
      session.profile?['subject'] == actor &&
      session.generation == generation;
  bool get available => mounted && foreground && identityMatches;
  @override
  void initState() {
    super.initState();
    actor = session.profile?['subject'] ?? '';
    generation = session.generation;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    operation = InvitationAcceptanceController(
        api: session.api,
        actor: actor,
        store: widget.store ?? InvitationAcceptanceStore(),
        isCurrent: () => available);
    session.addListener(_identityChanged);
    WidgetsBinding.instance.addObserver(this);
    operation.load();
  }

  void _identityChanged() {
    if (!mounted || identityMatches) return;
    tokenInput.clear();
    operation.forgetSecret();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || identityMatches) return;
      if (dialog?.isActive == true) dialog!.navigator?.removeRoute(dialog!);
      final route = ModalRoute.of(context);
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      tokenInput.clear();
      operation.forgetSecret();
      if (dialog?.isActive == true) dialog!.navigator?.removeRoute(dialog!);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    session.removeListener(_identityChanged);
    WidgetsBinding.instance.removeObserver(this);
    tokenInput.clear();
    tokenInput.dispose();
    operation.dispose();
    super.dispose();
  }

  Future<bool> _confirm(String title, String text, String action) async {
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

  Future<void> _preview() async {
    final value = tokenInput.text;
    tokenInput.clear();
    FocusScope.of(context).unfocus();
    await operation.inspect(value);
  }

  Future<void> _accept() async {
    final preview = operation.preview;
    if (preview == null || operation.busy) return;
    if (!operation.canAccept) {
      await operation.accept();
      return;
    }
    if (!await _confirm(
        '加入 ${preview['tenantName']}？',
        '角色：${memberRoleLabels[preview['role']]}\n范围：${preview['subjectName'] ?? ((preview['classes'] as List).isNotEmpty ? (preview['classes'] as List).map((r) => r['name']).join('、') : '此工作空间')}\n加入后按上述角色和范围访问。',
        '确认加入')) return;
    await operation.accept();
  }

  Future<void> _retry() async {
    final value = tokenInput.text.trim();
    if (!validInvitationToken(value)) {
      await operation.recover(retryToken: value);
      return;
    }
    if (!await _confirm(
        '重试原加入请求？', '使用原邀请码和原请求编号。不会接受另一份邀请，也不会恢复已撤销的成员资格。', '重试原操作')) return;
    tokenInput.clear();
    await operation.recover(retryToken: value);
  }

  Future<void> _refresh({bool clear = false}) async {
    if (!available || refreshing || operation.busy) return;
    if (clear &&
        !operation.committed &&
        !await _confirm('已核对当前工作空间？', '清除提醒不会撤销或重新执行加入操作。', '清除并刷新')) return;
    if (clear && !await operation.acknowledge()) return;
    if (!available) return;
    setState(() {
      refreshing = true;
      refreshError = null;
    });
    // Existing public restore flow re-reads identity and authoritative membership. No local grant.
    try {
      await session.initialize();
      if (mounted && available && session.error != null) {
        setState(() => refreshError = session.error);
      }
    } catch (e) {
      if (mounted && available) setState(() => refreshError = e);
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  Widget _tokenField({required String label}) => TextField(
      controller: tokenInput,
      obscureText: true,
      enableSuggestions: false,
      autocorrect: false,
      keyboardType: TextInputType.visiblePassword,
      maxLength: 128,
      enabled: !operation.busy && !refreshing,
      decoration: InputDecoration(
          labelText: label,
          helperText: '仅输入 43 位邀请码，不要输入账号密码。',
          prefixIcon: const Icon(Icons.key_outlined)));
  Widget _result() {
    final result = operation.result, now = result?['current'] as Json?;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(operation.committed ? '原加入操作已确认' : '核对上一次加入操作',
          style: Theme.of(context).textTheme.titleLarge),
      if (result != null) ...[
        const SizedBox(height: 12),
        Text('原加入角色：${memberRoleLabels[result['accepted']['role']]}'),
        Text(switch (now!['state']) {
          'ACTIVE' => '最近核对：仍为有效成员，当前角色为${memberRoleLabels[now['role']]}。',
          'REVOKED' => '最近核对：成员资格已被撤销。原加入成功不代表现在仍可访问。',
          _ => '最近核对：当前已无成员记录。原加入结果只用于核对历史。',
        }),
        if (now['state'] == 'ACTIVE' &&
            now['version'] != result['accepted']['memberVersion'])
          const Text('权限版本已变化，可能经历重新加入或权限调整。请以当前工作空间授权为准。'),
      ] else if (operation.queried)
        const Text('当前没有可读取的原提交结果，请核对工作空间。不能据此判断从未加入。'),
      const SizedBox(height: 12),
      OutlinedButton(
          onPressed: operation.busy ? null : () => operation.recover(),
          child: const Text('查询原加入结果')),
      if (!operation.committed) ...[
        const SizedBox(height: 12),
        _tokenField(label: '重新输入原邀请码'),
        OutlinedButton(
            onPressed: operation.busy ? null : _retry,
            child: const Text('重试原加入请求')),
      ],
      ExpansionTile(title: const Text('操作详情'), children: [
        SelectableText(
            '请求编号：${operation.pending!['requestId']}\n邀请编号：${operation.pending!['invitationId']}\n工作空间编号：${operation.pending!['tenantId']}'),
      ]),
      if (operation.queried)
        FilledButton(
            onPressed: operation.busy || refreshing
                ? null
                : () => _refresh(clear: true),
            child: Text(operation.committed ? '完成并刷新工作空间' : '已核对，清除提醒并刷新')),
    ]);
  }

  String _expiry(int milliseconds) {
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatShortDate(date)} ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date), alwaysUse24HourFormat: true)}';
  }

  Widget _previewCard(Json preview) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Icon(
            preview['tenantKind'] == 'FAMILY'
                ? Icons.home_outlined
                : Icons.school_outlined,
            size: 44),
        const SizedBox(height: 12),
        Text(preview['tenantName'],
            style: Theme.of(context).textTheme.headlineSmall),
        Text(preview['tenantKind'] == 'FAMILY' ? '家庭工作空间' : '机构工作空间'),
        const SizedBox(height: 20),
        Text('你将获得的职责', style: Theme.of(context).textTheme.titleMedium),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.badge_outlined),
            title: Text(memberRoleLabels[preview['role']]!),
            subtitle: Text(memberRoleDescription(preview['role']))),
        const SizedBox(height: 12),
        Text('管理或访问范围', style: Theme.of(context).textTheme.titleMedium),
        if (preview['subjectName'] != null)
          ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_outline),
              title: Text(preview['subjectName']))
        else if ((preview['classes'] as List).isNotEmpty) ...[
          for (final row in preview['classes'])
            ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.groups_outlined),
                title: Text(row['name']))
        ] else
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('按当前角色访问此工作空间；具体操作仍需服务端授权。')),
        const SizedBox(height: 12),
        Text('有效期至 ${_expiry(preview['expiresAt'])}（本机时间）'),
        if (preview['requiresRecentAuthentication'] == true)
          const Text('为保护账号，加入前可能需要再次验证身份。'),
        const SizedBox(height: 12),
        const Text('预览不会加入。确认后才会获得上述权限，儿童角色不会获得成人管理权限。'),
        TextButton(
            onPressed: operation.busy ? null : operation.forgetSecret,
            child: const Text('改用其他邀请码')),
      ]);
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('使用邀请码加入')),
        bottomNavigationBar: !available
            ? null
            : AnimatedBuilder(
                animation: operation,
                builder: (context, _) => operation.preview == null ||
                        operation.pending != null
                    ? const SizedBox.shrink()
                    : SafeArea(
                        child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                            child: FilledButton(
                                onPressed: operation.canAccept && !refreshing
                                    ? _accept
                                    : null,
                                child: const Text('核对并加入'))))),
        body: !available
            ? const Center(child: Text('加入内容已隐藏。'))
            : AnimatedBuilder(
                animation: operation,
                builder: (context, _) =>
                    ListView(padding: const EdgeInsets.all(20), children: [
                      if (operation.busy || refreshing)
                        const LinearProgressIndicator(),
                      if (operation.error != null)
                        Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(acceptanceFailure(operation.error!),
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error))),
                      if (refreshError != null)
                        Text('加入记录已核对，但工作空间刷新失败。请重试刷新。',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      if (!operation.loaded && !operation.busy)
                        OutlinedButton(
                            onPressed: operation.load,
                            child: const Text('重新读取加入记录')),
                      if (operation.pending != null)
                        _result()
                      else if (operation.preview != null)
                        _previewCard(operation.preview!)
                      else ...[
                        Text('先核对，再加入',
                            style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 12),
                        const Text(
                            '请使用邀请收件邮箱对应的已验证账号登录。输入邀请码后，可先查看家庭或机构、角色及范围。'),
                        const SizedBox(height: 20),
                        _tokenField(label: '邀请码'),
                        FilledButton(
                            onPressed: operation.canPreview && !refreshing
                                ? _preview
                                : null,
                            child: const Text('查看邀请内容')),
                      ],
                      if (operation.error is ParentApiException &&
                          (operation.error as ParentApiException).code ==
                              'REAUTH_REQUIRED') ...[
                        const Text('验证完成后重新打开此页，先查询原结果；需要重试时重新输入同一邀请码。'),
                        OutlinedButton(
                            onPressed:
                                operation.busy ? null : session.reauthenticate,
                            child: const Text('重新安全验证')),
                      ],
                      const SizedBox(height: 16),
                      OutlinedButton(
                          onPressed: operation.busy || refreshing
                              ? null
                              : () => _refresh(),
                          child: const Text('刷新已有工作空间')),
                    ])),
      );
}
