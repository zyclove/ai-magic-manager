import 'package:flutter/material.dart';
import '../core/family_collaboration.dart';
import '../core/parent_api.dart';
import '../core/parent_durable_storage.dart';
import '../core/parent_session.dart';
import 'family_members_page.dart'
    show familyCollaborationError, familyInvitationDate;
import 'family_workspace.dart';

class FamilyInvitationEntry extends StatelessWidget {
  final ParentSession session;
  const FamilyInvitationEntry({super.key, required this.session});
  @override
  Widget build(BuildContext context) => session.authenticated
      ? FamilyPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.mark_email_unread_outlined,
              color: familyInk, size: 32),
          const SizedBox(height: 12),
          Text('家人邀请了我', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('粘贴邀请链接，用被邀请的手机号确认加入。',
              style: TextStyle(color: familyMuted)),
          TextButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      FamilyInvitationAcceptancePage(session: session))),
              icon: const Icon(Icons.chevron_right),
              label: const Text('接受家庭邀请')),
        ]))
      : const SizedBox.shrink();
}

class FamilyInvitationAcceptancePage extends StatefulWidget {
  final ParentSession session;
  final FamilyInvitationIntent? initialIntent;
  final ParentDurableStorage? storage;
  const FamilyInvitationAcceptancePage(
      {super.key, required this.session, this.initialIntent, this.storage});
  @override
  State<FamilyInvitationAcceptancePage> createState() =>
      _FamilyInvitationAcceptancePageState();
}

class _FamilyInvitationAcceptancePageState
    extends State<FamilyInvitationAcceptancePage> with WidgetsBindingObserver {
  ParentSession get session => widget.session;
  late final String actor;
  late int generation;
  late FamilyInviteAcceptance coordinator;
  bool invalidated = false,
      foreground = true,
      loading = true,
      busy = false,
      adultGuardian = false,
      refreshing = false,
      completed = false;
  int epoch = 0;
  Object? error;
  String? receipt;
  String? acceptedTenant;
  String? previewedLink;
  Future<void>? mutation;
  final link = TextEditingController();
  bool get sameActor =>
      mounted &&
      !invalidated &&
      session.authenticated &&
      session.profile?['subject'] == actor;
  bool get current =>
      sameActor &&
      (refreshing || completed || session.generation == generation);
  bool get active => current && foreground;
  @override
  void initState() {
    super.initState();
    actor = session.profile?['subject'] as String? ?? '';
    generation = session.generation;
    session.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    _coordinator();
    load(initial: widget.initialIntent);
  }

  void _coordinator() {
    final value = epoch;
    coordinator = FamilyInviteAcceptance(
        api: session.api,
        actor: actor,
        available: () => active && epoch == value,
        storage: widget.storage);
  }

  void _changed() {
    if (!mounted) return;
    if (!session.authenticated ||
        session.profile?['subject'] != actor ||
        (!refreshing && !completed && session.generation != generation)) {
      setState(() {
        invalidated = true;
        link.clear();
        adultGuardian = false;
        previewedLink = null;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state != AppLifecycleState.resumed && foreground) {
      setState(() {
        foreground = false;
        epoch++;
        adultGuardian = false;
        link.clear();
        receipt = null;
        previewedLink = null;
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
    final value = epoch;
    await mutation;
    if (!active || epoch != value) return;
    busy = false;
    _coordinator();
    await load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_changed);
    link.dispose();
    super.dispose();
  }

  Future<void> load({FamilyInvitationIntent? initial}) async {
    if (!active || busy) return;
    final value = epoch, original = coordinator;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await original.load();
      if (!active || epoch != value || coordinator != original) return;
      if (original.pending == null && initial != null) {
        link.text = initial.link;
        await original.preview(initial);
        if (active && epoch == value && coordinator == original) {
          previewedLink = initial.link;
        }
      }
    } catch (e) {
      if (active && epoch == value && coordinator == original) {
        setState(() => error = e);
      }
    } finally {
      if (active && epoch == value && coordinator == original) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> preview() async {
    if (!active || busy || !coordinator.loaded || coordinator.pending != null) {
      return;
    }
    FamilyInvitationIntent intent;
    try {
      intent = FamilyInvitationIntent.parse(link.text);
    } catch (e) {
      setState(() => error = e);
      return;
    }
    await run(() async {
      await coordinator.preview(intent);
      if (active) setState(() => previewedLink = intent.link);
    });
  }

  Future<void> join() async {
    if (!active || previewedLink == null || !adultGuardian) return;
    FamilyInvitationIntent edited;
    try {
      edited = FamilyInvitationIntent.parse(link.text);
    } catch (_) {
      return;
    }
    if (edited.link != previewedLink ||
        coordinator.intent?.link != previewedLink) return;
    await run(() => coordinator.accept(adultGuardian: adultGuardian),
        joining: true);
  }

  Future<void> run(Future<void> Function() action,
      {bool joining = false}) async {
    if (!active || busy) return;
    final value = epoch, original = coordinator;
    setState(() {
      busy = true;
      error = null;
      receipt = null;
    });
    final operation = () async {
      try {
        await action();
        if (!active || epoch != value || coordinator != original) return;
        if (joining) {
          if (original.revoked) {
            setState(() => receipt = '上次加入已完成，但这位监护人已被移除。请联系家庭创建者。');
          } else if (original.acceptedTenant != null) {
            acceptedTenant = original.acceptedTenant;
            await finish(acceptedTenant!, value);
          }
        }
      } catch (e) {
        if (active && epoch == value && coordinator == original) {
          setState(() => error = e);
        }
      } finally {
        if (active && epoch == value && coordinator == original) {
          setState(() => busy = false);
        }
      }
    }();
    mutation = operation;
    await operation;
    if (identical(mutation, operation)) mutation = null;
  }

  Future<void> finish(String tenant, int value) async {
    if (!active || epoch != value) return;
    setState(() => refreshing = true);
    try {
      await session.refreshWorkspaces();
      if (!sameActor || !foreground || epoch != value) return;
      final target = session.tenants
          .where((item) => item['id'] == tenant && item['kind'] == 'FAMILY')
          .firstOrNull;
      if (target == null) throw const ParentApiException(403, 'SCOPE_DENIED');
      await session.selectTenant(target);
      if (!sameActor || !foreground || epoch != value) return;
      if (session.tenant?['id'] != tenant ||
          !{'OWNER', 'GUARDIAN'}.contains(session.role)) {
        throw const ParentApiException(403, 'SCOPE_DENIED');
      }
      setState(() {
        completed = true;
        receipt = '已加入家庭，可以一起处理申请和安排作息。';
        link.clear();
      });
    } finally {
      if (mounted && sameActor) {
        setState(() {
          generation = session.generation;
          refreshing = false;
        });
      }
    }
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

  @override
  Widget build(BuildContext context) {
    final details = previewedLink == null ? null : coordinator.details;
    return Scaffold(
        appBar: AppBar(title: const Text('接受家庭邀请')),
        body: !current
            ? const Center(
                child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('账号或登录状态已变化，请返回重新打开邀请。')))
            : !foreground
                ? const Center(child: Text('返回后会重新核对加入进度。'))
                : refreshing
                    ? const Center(child: Text('正在刷新家庭列表，请稍候。'))
                    : loading
                        ? const Center(child: CircularProgressIndicator())
                        : ListView(
                            padding: const EdgeInsets.all(20),
                            children: [
                                if (error != null)
                                  FamilyNotice(familyCollaborationError(error!),
                                      error: true),
                                if (receipt != null) FamilyNotice(receipt!),
                                if (error is ParentApiException &&
                                    (error as ParentApiException).code ==
                                        'REAUTH_REQUIRED')
                                  FilledButton(
                                      onPressed: busy ? null : reauthenticate,
                                      child: const Text('完成手机号验证')),
                                if (completed)
                                  FilledButton(
                                      onPressed: () {
                                        if (Navigator.of(context).canPop()) {
                                          Navigator.of(context).pop();
                                        }
                                      },
                                      child: const Text('返回家庭')),
                                if (!completed && !coordinator.loaded)
                                  OutlinedButton(
                                      onPressed: busy ? null : load,
                                      child: const Text('重新读取加入进度')),
                                if (!completed &&
                                    coordinator.loaded &&
                                    coordinator.pending != null)
                                  FamilyPanel(
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                        Text('上次加入待核对',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleLarge),
                                        const SizedBox(height: 8),
                                        const Text(
                                            '结果可能已保存。继续核对会使用原邀请和同一次加入请求，不会换用其他链接。'),
                                        const SizedBox(height: 16),
                                        FilledButton(
                                            onPressed: busy
                                                ? null
                                                : () => run(coordinator.retry,
                                                    joining: true),
                                            child: const Text('继续核对原加入')),
                                      ])),
                                if (!completed &&
                                    coordinator.loaded &&
                                    coordinator.pending == null &&
                                    acceptedTenant != null)
                                  FamilyPanel(
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                        const Text('加入结果已确认，请刷新家庭列表。'),
                                        const SizedBox(height: 12),
                                        FilledButton(
                                            onPressed: busy
                                                ? null
                                                : () => run(() async {
                                                      await finish(
                                                          acceptedTenant!,
                                                          epoch);
                                                    }),
                                            child: const Text('刷新家庭列表')),
                                      ])),
                                if (!completed &&
                                    coordinator.loaded &&
                                    coordinator.pending == null &&
                                    acceptedTenant == null &&
                                    !coordinator.revoked) ...[
                                  FamilyPanel(
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                        const Icon(
                                            Icons.family_restroom_outlined,
                                            color: familyInk,
                                            size: 36),
                                        const SizedBox(height: 12),
                                        Text('一起照顾孩子',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleLarge),
                                        const SizedBox(height: 8),
                                        const Text('请用被邀请的手机号登录，再粘贴家人分享的完整链接。'),
                                        const SizedBox(height: 16),
                                        TextField(
                                            key: const ValueKey(
                                                'family-invitation-link'),
                                            controller: link,
                                            onChanged: (_) => setState(() {
                                                  previewedLink = null;
                                                  adultGuardian = false;
                                                }),
                                            enabled: !busy,
                                            maxLines: 3,
                                            keyboardType: TextInputType.url,
                                            autocorrect: false,
                                            enableSuggestions: false,
                                            decoration: const InputDecoration(
                                                labelText: '邀请链接',
                                                hintText:
                                                    'aimanager://family-invitation?...')),
                                        const SizedBox(height: 16),
                                        OutlinedButton(
                                            onPressed: busy ? null : preview,
                                            child: const Text('查看邀请')),
                                      ])),
                                  if (details != null)
                                    FamilyPanel(
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                          Text(details.tenantName,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleLarge),
                                          const SizedBox(height: 8),
                                          const Text(
                                              '你将作为共同监护人加入，可查看使用情况、处理申请和调整规则。'),
                                          const SizedBox(height: 8),
                                          Text(
                                              '有效期至 ${familyInvitationDate(details.expiresAt)}',
                                              style: const TextStyle(
                                                  color: familyMuted)),
                                          CheckboxListTile(
                                              contentPadding: EdgeInsets.zero,
                                              value: adultGuardian,
                                              onChanged: busy
                                                  ? null
                                                  : (value) => setState(() =>
                                                      adultGuardian =
                                                          value == true),
                                              title: const Text(
                                                  '我是成人监护人，已获合法授权共同管理孩子的设备。'),
                                              subtitle: const Text(
                                                  '手机号验证用于账号确认，成人及监护身份由本人声明。')),
                                          const SizedBox(height: 12),
                                          FilledButton(
                                              onPressed: busy ||
                                                      !adultGuardian ||
                                                      details.state != 'PENDING'
                                                  ? null
                                                  : join,
                                              child: const Text('加入家庭')),
                                        ])),
                                ],
                                if (busy)
                                  const Padding(
                                      padding: EdgeInsets.all(16),
                                      child: LinearProgressIndicator()),
                              ]));
  }
}
