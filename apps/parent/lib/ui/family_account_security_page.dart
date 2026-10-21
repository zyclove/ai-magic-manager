import 'package:flutter/material.dart';

import '../core/family_account_security.dart';
import '../core/parent_session.dart';
import 'family_workspace.dart';

class FamilyAccountSecurityEntry extends StatelessWidget {
  final ParentSession session;
  const FamilyAccountSecurityEntry({super.key, required this.session});

  @override
  Widget build(BuildContext context) => ListTile(
      leading: const Icon(Icons.verified_user_outlined),
      title: const Text('账号与安全'),
      subtitle: const Text('手机号、微信与账号恢复'),
      trailing: const Icon(Icons.chevron_right),
      minVerticalPadding: 16,
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => FamilyAccountSecurityPage(session: session))));
}

class FamilyAccountSecurityPage extends StatefulWidget {
  final ParentSession session;
  final FamilyAccountSecurityCoordinator? coordinator;
  const FamilyAccountSecurityPage(
      {super.key, required this.session, this.coordinator});

  @override
  State<FamilyAccountSecurityPage> createState() => _FamilyAccountPageState();
}

class FamilyAccountRecoveryPage extends StatefulWidget {
  final ParentSession session;
  final FamilyAccountSecurityCoordinator? coordinator;
  const FamilyAccountRecoveryPage(
      {super.key, required this.session, this.coordinator});

  @override
  State<FamilyAccountRecoveryPage> createState() =>
      _FamilyAccountRecoveryState();
}

mixin _AccountPage<T extends StatefulWidget>
    on State<T>, WidgetsBindingObserver {
  ParentSession get session;
  FamilyAccountSecurityCoordinator? get providedCoordinator;
  late final FamilyAccountSecurityCoordinator controller;
  BuildContext? _confirmation;
  int _confirmationEpoch = 0;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    controller = providedCoordinator ??
        FamilyAccountSecurityCoordinator.forSession(session: session);
    controller.setForeground(WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
    controller.addListener(_changed);
    session.addListener(_identityChanged);
    WidgetsBinding.instance.addObserver(this);
    controller.restore();
  }

  @override
  void dispose() {
    _dismissConfirmation();
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_identityChanged);
    controller.removeListener(_changed);
    if (providedCoordinator == null) controller.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _identityChanged() {
    _confirmationEpoch++;
    _dismissConfirmation();
    controller.identityChanged();
  }

  void _dismissConfirmation() {
    final dialog = _confirmation;
    _confirmation = null;
    if (_confirming &&
        dialog != null &&
        dialog.mounted &&
        ModalRoute.of(dialog)?.isCurrent == true) {
      _confirming = false;
      Navigator.of(dialog).pop(false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    final resumed = state == AppLifecycleState.resumed;
    if (!resumed) {
      _confirmationEpoch++;
      _dismissConfirmation();
    }
    controller.setForeground(resumed);
    if (resumed) controller.refresh();
  }

  Future<bool> _confirm(String title, String explanation) async {
    if (_confirming || !controller.foreground || controller.busy) return false;
    final epoch = _confirmationEpoch;
    final identity = controller.identity();
    _confirming = true;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          _confirmation = dialogContext;
          return AlertDialog(
              title: Text(title),
              content: SingleChildScrollView(child: Text(explanation)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('暂不操作')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('验证并继续')),
              ]);
        });
    _confirming = false;
    _confirmation = null;
    return mounted &&
        confirmed == true &&
        controller.foreground &&
        epoch == _confirmationEpoch &&
        identity.same(controller.identity());
  }

  Future<void> perform(String action, String title, String explanation) async {
    if (!controller.canPerform(action)) return;
    if (await _confirm(title, explanation)) await controller.perform(action);
  }

  Future<void> acknowledge() async {
    if (!controller.canAcknowledgeCurrentState) return;
    if (await _confirm(
        '结束本次操作', '已重新读取当前账号状态。本次操作是否完成仍以当前手机号和微信状态为准。结束后可重新发起新的验证。')) {
      await controller.acknowledgeCurrentState();
    }
  }

  List<Widget> stateNotices() => [
        if (controller.busy)
          const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: LinearProgressIndicator()),
        if (!controller.foreground) const FamilyNotice('回到此页面后，会重新核对账号状态。'),
        if (controller.error != null)
          FamilyNotice(familyAccountError(controller.error!), error: true),
        if (controller.completedAction != null)
          FamilyNotice(switch (controller.completedAction) {
            'CHANGE_PHONE' => '手机号已更换，家庭、设备、订单和会员保留在原账号中。',
            'BIND_WECHAT' => '微信已绑定，下次可用微信登录同一个账号。',
            'UNBIND_WECHAT' => '微信已解绑，请使用已验证的手机号登录。',
            'RECOVER_PHONE' => '已核对账号恢复完成。请使用新手机号或已绑定微信登录原账号。',
            _ => '已重新核对当前账号状态。',
          }),
        if (controller.pendingForAnotherAccount)
          const FamilyNotice('另一账号还有待核对操作。请返回原账号登录后核对，暂不继续新的操作。'),
        if (controller.pending != null && !controller.pendingForAnotherAccount)
          FamilyPanel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('上次操作的结果还需核对',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
                const SizedBox(height: 8),
                const Text('离开验证页面不代表操作未生效。先读取当前状态，避免重复操作。若未完成验证，请稍后再核对。'),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                    onPressed: controller.busy ? null : controller.refresh,
                    icon: const Icon(Icons.refresh),
                    label: const Text('核对当前账号')),
                if (controller.canAcknowledgeCurrentState) ...[
                  const SizedBox(height: 8),
                  TextButton(
                      onPressed: acknowledge,
                      child: const Text('已核对当前账号，结束本次操作')),
                ],
              ])),
      ];

  Widget refreshButton() => OutlinedButton.icon(
      onPressed: controller.busy ? null : controller.refresh,
      icon: const Icon(Icons.refresh),
      label: const Text('重新读取'));
}

class _FamilyAccountPageState extends State<FamilyAccountSecurityPage>
    with WidgetsBindingObserver, _AccountPage {
  @override
  ParentSession get session => widget.session;
  @override
  FamilyAccountSecurityCoordinator? get providedCoordinator =>
      widget.coordinator;

  @override
  Widget build(BuildContext context) {
    final status = controller.status;
    return Scaffold(
        appBar: AppBar(title: const Text('账号与安全')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          ...stateNotices(),
          if (controller.needsLogin)
            FamilyPanel(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  const Text('先登录原账号，再核对手机号和微信。'),
                  const SizedBox(height: 16),
                  FilledButton(
                      onPressed: controller.busy
                          ? null
                          : () async {
                              await session.signIn();
                              if (mounted) await controller.refresh();
                            },
                      child: const Text('重新登录')),
                ])),
          if (status != null) ...[
            _SecurityCard(
                icon: Icons.phone_android_outlined,
                title: '手机号',
                value: status.phoneVerified ? status.phoneMasked! : '尚未验证',
                description: '用于验证码登录、账号恢复和敏感操作验证。',
                actionLabel: '更换手机号',
                onAction: controller.canPerform('CHANGE_PHONE')
                    ? () => perform('CHANGE_PHONE', '更换手机号',
                        '先验证当前手机号，再验证新手机号。家庭、设备、订单和会员保留在同一个账号中；完成后其他设备上的旧登录会失效。')
                    : null),
            const SizedBox(height: 16),
            _SecurityCard(
                icon: Icons.chat_bubble_outline,
                title: '微信',
                value: status.wechatBound ? '已绑定' : '未绑定',
                description: status.wechatBound
                    ? '可用已绑定微信登录，原手机号停用时也可用于找回账号。'
                    : '绑定后可快捷登录，也为手机号停用时保留恢复方式。',
                actionLabel: status.wechatBound ? '解绑微信' : '绑定微信',
                onAction: controller.canPerform(
                        status.wechatBound ? 'UNBIND_WECHAT' : 'BIND_WECHAT')
                    ? () => status.wechatBound
                        ? perform('UNBIND_WECHAT', '解绑微信',
                            '请验证当前手机号。解绑后无法再用此微信登录或找回账号，请确认手机号仍可收短信。完成后其他设备上的旧登录会失效。')
                        : perform('BIND_WECHAT', '绑定微信',
                            '将打开微信授权，并验证当前手机号。已属于其他账号的微信不能直接合并。完成后其他设备上的旧登录会失效。')
                    : null),
            const SizedBox(height: 16),
            if (!status.accountSecurityAvailable ||
                !controller.actionsAvailable)
              const FamilyNotice('手机号和微信变更暂未开放，请保留现有登录方式。'),
          ] else if (!controller.busy && !controller.needsLogin)
            const FamilyNotice('暂时无法核对账号状态，请重新读取后再操作。'),
          const SizedBox(height: 16),
          refreshButton(),
          const SizedBox(height: 16),
          TextButton.icon(
              onPressed: controller.busy
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) =>
                          FamilyAccountRecoveryPage(session: session))),
              icon: const Icon(Icons.help_outline),
              label: const Text('手机号无法使用？找回账号')),
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('账号操作通过安全验证页面完成，本页不收集验证码。',
                  style: TextStyle(color: familyMuted))),
        ]));
  }
}

class _FamilyAccountRecoveryState extends State<FamilyAccountRecoveryPage>
    with WidgetsBindingObserver, _AccountPage {
  @override
  ParentSession get session => widget.session;
  @override
  FamilyAccountSecurityCoordinator? get providedCoordinator =>
      widget.coordinator;

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('找回账号')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        ...stateNotices(),
        const Padding(
            padding: EdgeInsets.only(bottom: 20),
            child: Text('继续使用原账号，家庭、孩子设备、订单和会员都会保留。',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
        _SecurityCard(
            icon: Icons.sms_outlined,
            title: '原手机号还能收短信',
            value: '验证码登录即可恢复',
            description: '无需记住密码。登录后可在“账号与安全”更换手机号。',
            actionLabel: '手机号登录',
            onAction: controller.busy
                ? null
                : () async {
                    await session.signInWithProvider('phone');
                    if (mounted) await controller.refresh();
                  }),
        const SizedBox(height: 16),
        _SecurityCard(
            icon: Icons.chat_bubble_outline,
            title: '原手机号已停用',
            value: '使用此前绑定的微信',
            description: '验证已绑定微信后，再验证新手机号。未绑定过的微信无法用于找回原账号。',
            actionLabel: '用已绑定微信找回',
            onAction: controller.canPerform('RECOVER_PHONE')
                ? () => perform('RECOVER_PHONE', '用微信找回账号',
                    '请使用此前绑定的微信授权，然后验证新手机号。不会创建另一个家庭账号。完成后其他设备上的旧登录会失效。')
                : null),
        const SizedBox(height: 16),
        const FamilyPanel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('手机号和已绑定微信都无法使用',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          SizedBox(height: 8),
          Text(
              '请先向手机号或微信服务商申请恢复原登录方式。若仍无法恢复，请通过产品帮助渠道说明情况，准备订单信息以便核对；不要发送验证码或密码。'),
          SizedBox(height: 8),
          Text('为保护家庭数据，无法仅凭昵称、孩子姓名或订单截图自动变更账号。',
              style: TextStyle(color: familyMuted)),
        ])),
        const SizedBox(height: 16),
        if (!controller.recoveryAvailable)
          const FamilyNotice('微信找回暂未开放，请先使用原手机号登录或按帮助说明恢复原登录方式。'),
        if (controller.pending != null || controller.error != null)
          refreshButton(),
      ]));
}

class _SecurityCard extends StatelessWidget {
  final IconData icon;
  final String title, value, description, actionLabel;
  final VoidCallback? onAction;
  const _SecurityCard(
      {required this.icon,
      required this.title,
      required this.value,
      required this.description,
      required this.actionLabel,
      this.onAction});

  @override
  Widget build(BuildContext context) => FamilyPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: familyInk, size: 28),
          const SizedBox(width: 12),
          Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 18))),
        ]),
        const SizedBox(height: 12),
        Text(value,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 20)),
        const SizedBox(height: 8),
        Text(description, style: const TextStyle(color: familyMuted)),
        const SizedBox(height: 16),
        SizedBox(
            width: double.infinity,
            child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12)),
                onPressed: onAction,
                child: Text(actionLabel, textAlign: TextAlign.center))),
      ]));
}
