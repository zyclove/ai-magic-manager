import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/family.dart';
import '../core/family_collaboration.dart';
import '../core/parent_api.dart';
import '../core/parent_durable_storage.dart';
import '../core/parent_session.dart';
import 'family_workspace.dart';

String familyCollaborationError(Object error) {
  if (error is ParentApiException) {
    return switch (error.code) {
      'ENTITLEMENT_REQUIRED' => '邀请共同监护需要有效家庭会员或试用，请家庭创建者查看会员状态。',
      'REAUTH_REQUIRED' => '请完成手机号安全验证，再重新打开本页核对原操作。',
      'VERIFIED_PHONE_REQUIRED' => '请先通过手机号登录完成验证，再打开家庭协作。',
      'GUARDIAN_DECLARATION_REQUIRED' => '请阅读并确认成人监护声明。',
      'INVITATION_UNAVAILABLE' => '邀请已到期、撤销或被使用，请联系家庭创建者。',
      'MEMBER_ALREADY_EXISTS' => '你已经是这个家庭的成员，请刷新家庭列表。',
      'FAMILY_INVITATION_ALREADY_PENDING' => '这个手机号已有待接受邀请，请查看下方邀请状态。',
      'INVITATION_ALREADY_ACCEPTED' => '对方已接受邀请，请在家庭成员中管理。',
      'FAMILY_INVITATION_RATE_LIMITED' => '操作较频繁，请稍后再试。',
      'CLIPBOARD_UNAVAILABLE' => '暂时无法复制邀请链接，请重试。原邀请已保留。',
      _ => familyError(error),
    };
  }
  if (error is FormatException) return error.message.toString();
  return familyError(error);
}

String familyInvitationDate(int value) {
  final date = DateTime.fromMillisecondsSinceEpoch(value, isUtc: true)
      .add(const Duration(hours: 8));
  return '${date.month} 月 ${date.day} 日 ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}（北京时间）';
}

class FamilyMembersEntry extends StatelessWidget {
  final ParentSession session;
  const FamilyMembersEntry({super.key, required this.session});
  @override
  Widget build(BuildContext context) => session.authenticated &&
          session.tenant?['kind'] == 'FAMILY' &&
          session.canDecide
      ? FamilyPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.family_restroom_outlined,
              color: familyInk, size: 32),
          const SizedBox(height: 12),
          Text('家庭成员', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('和另一位家长一起处理申请、安排作息。',
              style: TextStyle(color: familyMuted)),
          TextButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => FamilyMembersPage(session: session))),
              icon: const Icon(Icons.chevron_right),
              label: const Text('查看家庭成员')),
        ]))
      : const SizedBox.shrink();
}

class FamilyMembersPage extends StatefulWidget {
  final ParentSession session;
  final ParentDurableStorage? storage;
  const FamilyMembersPage({super.key, required this.session, this.storage});
  @override
  State<FamilyMembersPage> createState() => _FamilyMembersPageState();
}

class _FamilyMembersPageState extends State<FamilyMembersPage>
    with FamilyScope, WidgetsBindingObserver {
  @override
  ParentSession get session => widget.session;
  late FamilyService scoped;
  late FamilyInviteCoordinator invites;
  late FamilyCollaborationChange changes;
  FamilyMembersSnapshot? members;
  final phone = TextEditingController();
  bool foreground = true, loading = true, busy = false, adultGuardian = false;
  int epoch = 0;
  Object? error;
  String? receipt;
  Future<void>? mutation;
  BuildContext? confirmationContext;
  bool get active => current && foreground;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_changed);
    _coordinators();
    load();
  }

  void _coordinators() {
    final generation = epoch;
    scoped = FamilyService(
        api: session.api,
        tenantId: scopeTenant,
        available: () => active && epoch == generation);
    invites = FamilyInviteCoordinator(
        service: scoped, actor: scopeActor, storage: widget.storage);
    changes = FamilyCollaborationChange(
        service: scoped, actor: scopeActor, storage: widget.storage);
  }

  void _dismiss() {
    final dialog = confirmationContext;
    confirmationContext = null;
    if (dialog != null && dialog.mounted) Navigator.of(dialog).pop(false);
  }

  void _changed() {
    if (!current) _dismiss();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state != AppLifecycleState.resumed && foreground) {
      _dismiss();
      setState(() {
        foreground = false;
        epoch++;
        receipt = null;
        adultGuardian = false;
        phone.clear();
      });
    } else if (state == AppLifecycleState.resumed && !foreground) {
      setState(() {
        foreground = true;
        loading = true;
      });
      _resume();
    }
  }

  Future<void> _resume() async {
    final generation = epoch;
    await mutation;
    if (!active || generation != epoch) return;
    busy = false;
    _coordinators();
    await load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_changed);
    phone.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (!active || busy) return;
    await _read();
  }

  Future<void> _read() async {
    final generation = epoch, original = invites;
    if (!active) return;
    setState(() {
      loading = true;
      error = null;
      members = null;
    });
    try {
      final snapshot = await readFamilyMembersSnapshot(scoped);
      if (snapshot.currentRole != scopeRole) {
        throw const ParentApiException(403, 'SCOPE_DENIED');
      }
      await Future.wait([invites.load(), changes.load()]);
      if (active && epoch == generation && invites == original) {
        setState(() => members = snapshot);
      }
    } catch (e) {
      if (active && epoch == generation && invites == original) {
        setState(() => error = e);
      }
    } finally {
      if (active && epoch == generation && invites == original) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> run(Future<void> Function() action, {String? success}) async {
    if (!active || busy) return;
    final generation = epoch, original = invites;
    setState(() {
      busy = true;
      error = null;
      receipt = null;
    });
    final operation = () async {
      try {
        await action();
        if (!active || epoch != generation || invites != original) return;
        phone.clear();
        if (success != null) setState(() => receipt = success);
        await _read();
      } catch (e) {
        if (active && epoch == generation && invites == original) {
          setState(() => error = e);
        }
      } finally {
        if (active && epoch == generation && invites == original) {
          setState(() => busy = false);
        }
      }
    }();
    mutation = operation;
    await operation;
    if (identical(mutation, operation)) mutation = null;
  }

  Future<void> create() async {
    if (members == null || scopeRole != 'OWNER' || !active) return;
    try {
      normalizeFamilyPhone(phone.text);
    } catch (e) {
      setState(() => error = e);
      return;
    }
    final number = phone.text,
        requiresDeclaration = members!.guardianDeclarationRequired;
    if (requiresDeclaration && !adultGuardian) return;
    await run(() async {
      if (requiresDeclaration) {
        await scoped.write('POST', '/family-guardian-declaration', body: {
          'adultGuardian': true,
          'declarationVersion': 'family-guardian-v1'
        });
      }
      await invites.create(number);
    });
  }

  Future<void> change(
      {required String kind,
      required String target,
      int? version,
      required String label}) async {
    if (!active || busy || changes.pending != null) return;
    final generation = epoch;
    final result = await showDialog<bool>(
        context: context,
        builder: (dialog) {
          confirmationContext = dialog;
          return AlertDialog(
              title: Text(kind == 'REMOVE_MEMBER' ? '移除这位监护人？' : '撤销这份邀请？'),
              scrollable: true,
              content: Text(kind == 'REMOVE_MEMBER'
                  ? '$label 将无法再查看或管理这个家庭。孩子的设备和规则会保留。'
                  : '$label 将无法使用这份链接加入家庭。已经加入的成员需要单独管理。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialog, true),
                    child: Text(kind == 'REMOVE_MEMBER' ? '确认移除' : '确认撤销'))
              ]);
        });
    confirmationContext = null;
    if (result != true || !active || epoch != generation) return;
    await run(() => changes.start(kind: kind, target: target, version: version),
        success:
            kind == 'REMOVE_MEMBER' ? '成员操作已保存，请核对当前列表。' : '邀请操作已保存，请核对当前状态。');
  }

  Future<void> reauthenticate() async {
    if (!active || busy) return;
    final navigator = Navigator.of(context);
    setState(() => busy = true);
    final result = await session.reauthenticateFamily();
    if (!mounted) return;
    if (result) {
      if (navigator.canPop()) navigator.pop();
    } else if (active) {
      setState(() {
        busy = false;
        error = session.error ?? '安全验证未完成，请重试。';
      });
    }
  }

  Future<void> copyLink() async {
    if (!active || busy || invites.shareIntent == null) return;
    final generation = epoch;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: invites.shareIntent!.link));
      if (active && generation == epoch) {
        setState(() => receipt = '邀请链接已复制，请只分享给对应手机号的家人。');
        messenger.showSnackBar(const SnackBar(content: Text('已复制邀请链接')));
      }
    } catch (_) {
      if (active && generation == epoch) {
        setState(
            () => error = const ParentApiException(0, 'CLIPBOARD_UNAVAILABLE'));
        messenger.showSnackBar(
            const SnackBar(content: Text('暂时无法复制邀请链接，请重试。原邀请已保留。')));
      }
    }
  }

  Widget _pendingChange() => FamilyPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('上次家庭操作待核对', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('请先查询当前成员和邀请。继续核对会使用上次同一个目标，不会移除其他成员或撤销其他邀请。'),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(
              onPressed: busy ? null : load, child: const Text('查询家庭状态')),
          FilledButton(
              onPressed: busy
                  ? null
                  : () => run(changes.retry, success: '原操作已核对，请查看当前列表。'),
              child: const Text('继续核对原操作'))
        ]),
      ]));
  Widget _invitePanel() {
    final pending = invites.pending, share = invites.shareIntent;
    if (pending != null) {
      return FamilyPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('上次邀请待核对', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('结果可能已保存。查询只读取状态；继续核对使用原邀请，不会另建邀请。'),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(
              onPressed: busy ? null : load, child: const Text('查询邀请状态')),
          FilledButton(
              onPressed: busy
                  ? null
                  : () => run(() async {
                        await invites.retry();
                      }),
              child: const Text('继续核对原邀请'))
        ]),
      ]));
    }
    if (share != null) {
      final summary =
          invites.invitations.where((i) => i.id == share.id).firstOrNull;
      final shareable = summary?.state == 'PENDING' &&
          (invites.shareExpiresAt ?? 0) > DateTime.now().millisecondsSinceEpoch;
      return FamilyPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.link_outlined, color: familyInk, size: 36),
        const SizedBox(height: 12),
        Text(shareable ? '邀请已准备好' : '这份邀请当前不可使用',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (summary != null) Text('发送给 ${summary.targetPhoneMasked}'),
        if (invites.shareExpiresAt != null)
          Text('有效期至 ${familyInvitationDate(invites.shareExpiresAt!)}'),
        const SizedBox(height: 12),
        const Text('链接不含手机号和孩子资料，仍请只分享给对应的家人。对方需用被邀请的手机号登录后确认加入。'),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (shareable)
            FilledButton.icon(
                onPressed: busy ? null : copyLink,
                icon: const Icon(Icons.copy_outlined),
                label: const Text('复制邀请链接')),
          OutlinedButton(
              onPressed: busy ? null : () => run(invites.finishSharing),
              child: const Text('邀请另一位家人'))
        ]),
        const SizedBox(height: 8),
        const Text('邀请另一位只清除本机的分享进度，原邀请仍可在下方撤销。',
            style: TextStyle(color: familyMuted)),
      ]));
    }
    return FamilyPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('邀请共同监护', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      const Text('输入另一位家长的中国大陆手机号，再把邀请链接分享给对方。'),
      const SizedBox(height: 16),
      TextField(
          key: const ValueKey('family-invite-phone'),
          controller: phone,
          enabled: !busy && changes.pending == null,
          keyboardType: TextInputType.phone,
          autofillHints: const [],
          maxLength: 16,
          decoration: const InputDecoration(
              labelText: '家人的手机号', hintText: '11 位手机号', counterText: '')),
      if (members!.guardianDeclarationRequired)
        CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: adultGuardian,
            onChanged: busy
                ? null
                : (value) => setState(() => adultGuardian = value == true),
            title: const Text('我是成人监护人，已获合法授权共同管理孩子的设备。'),
            subtitle: const Text('手机号验证用于账号确认，成人及监护身份由本人声明。')),
      const SizedBox(height: 16),
      FilledButton(
          onPressed: busy ||
                  changes.pending != null ||
                  !invites.loaded ||
                  members!.guardianDeclarationRequired && !adultGuardian
              ? null
              : create,
          child: const Text('生成邀请链接')),
      const SizedBox(height: 8),
      const Text('新邀请需要有效会员或试用。不会自动发送短信。',
          style: TextStyle(color: familyMuted)),
    ]));
  }

  Widget _member(FamilyMember member) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(
              backgroundColor: const Color(0xFFE5EFF4),
              child: Icon(
                  member.role == 'OWNER'
                      ? Icons.home_outlined
                      : Icons.person_outline,
                  color: familyInk)),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(member.displayName,
                    style: Theme.of(context).textTheme.titleMedium),
                Text(member.role == 'OWNER' ? '家庭创建者' : '共同监护',
                    style: const TextStyle(color: familyMuted))
              ]))
        ]),
        if (scopeRole == 'OWNER' && member.canRemove)
          TextButton(
              onPressed: busy || changes.pending != null
                  ? null
                  : () => change(
                      kind: 'REMOVE_MEMBER',
                      target: member.memberKey,
                      version: member.version,
                      label: member.displayName),
              child: const Text('移除')),
      ]));
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('家庭成员')),
      body: !current
          ? const Center(child: Text('当前家庭或权限已变化，请返回重新打开。'))
          : !foreground
              ? const Center(child: Text('返回后会重新核对家庭状态。'))
              : loading
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: load,
                      child: ListView(
                          padding: const EdgeInsets.all(20),
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            if (receipt != null) FamilyNotice(receipt!),
                            if (error != null)
                              FamilyNotice(familyCollaborationError(error!),
                                  error: true),
                            if (error is ParentApiException &&
                                (error as ParentApiException).code ==
                                    'REAUTH_REQUIRED')
                              FilledButton(
                                  onPressed: busy ? null : reauthenticate,
                                  child: const Text('完成手机号验证')),
                            if (members == null ||
                                !invites.loaded ||
                                !changes.loaded)
                              OutlinedButton(
                                  onPressed: busy ? null : load,
                                  child: const Text('重新读取家庭成员')),
                            if (members != null &&
                                invites.loaded &&
                                changes.loaded) ...[
                              FamilyPanel(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text('一起照顾孩子的数字生活',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge),
                                    const SizedBox(height: 8),
                                    const Text('共同监护可以查看使用情况、处理申请和调整家庭规则。',
                                        style: TextStyle(color: familyMuted)),
                                    for (final member in members!.members)
                                      _member(member),
                                    if (members!.members.isEmpty)
                                      const Text('暂未读取到家庭成人成员，请刷新后再操作。')
                                  ])),
                              if (changes.pending != null) _pendingChange(),
                              if (scopeRole == 'OWNER') _invitePanel(),
                              if (scopeRole == 'GUARDIAN')
                                const FamilyNotice('你是共同监护人。邀请和移除成员由家庭创建者管理。'),
                              if (invites.invitations.isNotEmpty)
                                FamilyPanel(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      Text('邀请状态',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleLarge),
                                      for (final invitation
                                          in invites.invitations)
                                        Padding(
                                            padding:
                                                const EdgeInsets.only(top: 16),
                                            child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                      invitation
                                                          .targetPhoneMasked,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .titleMedium),
                                                  Text(switch (
                                                      invitation.state) {
                                                    'PENDING' => '等待家人接受',
                                                    'ACCEPTED' => '已接受',
                                                    'EXPIRED' => '已到期',
                                                    _ => '已撤销'
                                                  }),
                                                  if (invitation.state ==
                                                      'PENDING')
                                                    Text(
                                                        '有效期至 ${familyInvitationDate(invitation.expiresAt)}',
                                                        style: const TextStyle(
                                                            color:
                                                                familyMuted)),
                                                  if (scopeRole == 'OWNER' &&
                                                      invitation.state ==
                                                          'PENDING')
                                                    TextButton(
                                                        onPressed: busy ||
                                                                changes.pending !=
                                                                    null
                                                            ? null
                                                            : () => change(
                                                                kind:
                                                                    'REVOKE_INVITATION',
                                                                target:
                                                                    invitation
                                                                        .id,
                                                                label: invitation
                                                                    .targetPhoneMasked),
                                                        child:
                                                            const Text('撤销邀请')),
                                                ])),
                                    ])),
                              if (busy)
                                const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: LinearProgressIndicator()),
                            ],
                          ])));
}
