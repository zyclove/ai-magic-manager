import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/family_identity_controller.dart';
import '../core/family_identity_repository.dart';
import 'design.dart';
import 'family_identity_editor.dart';
import 'family_identity_release_panel.dart';
import 'family_identity_acceptance_panel.dart';

class IdentityProvidersPage extends StatefulWidget {
  final Api api;
  final String actor;
  final bool canRead, canManage, canTest, canPublish, canRollback;
  final Listenable changes;
  final bool Function() isCurrent;
  final VoidCallback reauthenticate;
  final IdentityProviderOperationStorage? storage;
  const IdentityProvidersPage(
      {super.key,
      required this.api,
      required this.actor,
      required this.canRead,
      required this.canManage,
      required this.canTest,
      this.canPublish = false,
      this.canRollback = false,
      required this.changes,
      required this.isCurrent,
      required this.reauthenticate,
      this.storage});
  @override
  State<IdentityProvidersPage> createState() => _IdentityProvidersPageState();
}

class _IdentityProvidersPageState extends State<IdentityProvidersPage>
    with WidgetsBindingObserver {
  late final FamilyIdentityController controller;
  final editorKey = GlobalKey<IdentityProvidersEditorState>();
  bool foreground = true, dialogOpen = false;
  bool get current => mounted && foreground && widget.isCurrent();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = FamilyIdentityController(
        repository:
            FamilyIdentityRepository(api: widget.api, current: () => current),
        actor: widget.actor,
        current: () => current,
        canManage: () => widget.canManage,
        canTest: () => widget.canTest,
        canPublish: () => widget.canPublish,
        canRollback: () => widget.canRollback,
        storage: widget.storage,
        clearSensitiveInput: () =>
            editorKey.currentState?.clearSensitiveInput());
    widget.changes.addListener(scopeChanged);
    controller.load();
  }

  void closeEditor() {
    final editor = editorKey.currentState;
    editor?.clearSensitiveInput();
    if (editor != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (editor.mounted &&
            ModalRoute.of(editor.context)?.isCurrent == true) {
          Navigator.of(editor.context).pop();
        }
      });
    }
  }

  void scopeChanged() {
    if (!widget.isCurrent()) {
      controller.invalidate();
      closeEditor();
    }
  }

  @override
  void didUpdateWidget(covariant IdentityProvidersPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) {
      oldWidget.changes.removeListener(scopeChanged);
      widget.changes.addListener(scopeChanged);
    }
    if (oldWidget.actor != widget.actor ||
        oldWidget.api != widget.api ||
        oldWidget.canRead != widget.canRead ||
        oldWidget.canManage != widget.canManage ||
        oldWidget.canTest != widget.canTest ||
        oldWidget.canPublish != widget.canPublish ||
        oldWidget.canRollback != widget.canRollback ||
        !widget.isCurrent()) {
      controller.invalidate();
      closeEditor();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      controller.clearInputs();
      closeEditor();
    } else {
      controller.load();
    }
  }

  @override
  void dispose() {
    widget.changes.removeListener(scopeChanged);
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  void reauthenticate() {
    controller.prepareReauthentication();
    closeEditor();
    widget.reauthenticate();
  }

  Future<void> edit() async {
    if (!controller.canSave || !current || dialogOpen) return;
    dialogOpen = true;
    try {
      await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => Dialog(
              child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: 640,
                      maxHeight: MediaQuery.sizeOf(dialogContext).height * .88),
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: IdentityProvidersEditor(
                          key: editorKey,
                          currentVersion: controller.version,
                          isCurrent: () => current && !controller.invalidated,
                          onSave: (settings, replacements, clearToken) async {
                            await controller.save(settings,
                                replacements: replacements,
                                clearSmsSecurityToken: clearToken);
                            if (dialogContext.mounted &&
                                ModalRoute.of(dialogContext)?.isCurrent ==
                                    true) {
                              Navigator.of(dialogContext).pop();
                            }
                          })))));
    } finally {
      dialogOpen = false;
    }
  }

  Widget providerCard(
          String title, IconData icon, bool configured, String description) =>
      Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: navy),
          const SizedBox(width: 10),
          Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)))
        ]),
        const SizedBox(height: 16),
        Text(configured ? '配置已登记' : '待配置',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(description,
            style: const TextStyle(color: muted, fontSize: 16, height: 1.6)),
      ]));
  Widget nextAction() {
    String title, description;
    VoidCallback? action;
    String? label;
    if (controller.needsReauthentication) {
      title = '先完成安全验证';
      description = '管理员敏感操作需要近期多因素认证，密钥输入不会随验证保存。';
      action = reauthenticate;
      label = '重新安全验证';
    } else if (controller.pending != null) {
      title = '先核对原操作';
      description = '上次提交的结果尚未确认，当前不会重新发送密钥。';
      action = controller.recover;
      label = '核对原操作';
    } else if (controller.releaseStatus?.activeOperation != null) {
      title = '先核对正在处理的部署';
      description = '当前部署待确认，请在发布卡查看进度并核对生效状态。';
    } else if (controller.status?.capabilities.secretStorageReady == false) {
      title = '先准备安全存储';
      description = '请联系部署管理员准备加密密钥存储，再回到本页填写配置。';
    } else if (controller.version == null) {
      title = '先填写供应商配置';
      description = '准备短信签名、模板和微信移动应用资料，密钥只写不回读。';
      if (controller.canSave) {
        action = edit;
        label = '填写配置';
      }
    } else if (!widget.canManage && (widget.canPublish || widget.canRollback)) {
      title = widget.canPublish && controller.preparation?.status == 'PREPARED'
          ? '发布准备已就绪'
          : '配置由管理员维护';
      description =
          widget.canPublish && controller.preparation?.status == 'PREPARED'
              ? '已自动读取当前版本的发布准备，请在下方确认发布目标。'
              : widget.canPublish
                  ? '请等待配置管理员生成发布准备，再刷新本页。'
                  : '可在下方查看服务器允许的历史版本并预览回退影响。';
    } else if (const {'REGISTER_RUN', 'PREPARE_PILOT'}
        .contains(controller.acceptanceStatus?.nextAction)) {
      title = '继续真实联调';
      description = controller.acceptanceStatus?.nextAction == 'REGISTER_RUN'
          ? '请在下方建立本次验收，再按手机步骤核对结果。'
          : '消费者入口仍关闭，请查看下方独立试点的准备要求。';
    } else if (controller.validation == null) {
      title = '先检查配置';
      description = '先核对格式和准备条件，再安排受控发布与真实联调。';
      if (controller.canValidate) {
        action = controller.validate;
        label = '检查当前配置';
      }
    } else if (controller.validation!.readinessStatus == 'BLOCKED') {
      title = '补齐待处理项目';
      description = '请查看下方检查结果，修改配置后重新检查。';
      if (controller.canSave) {
        action = edit;
        label = '修改配置';
      }
    } else if (controller.preparation?.status != 'PREPARED') {
      title = '准备受控发布';
      description = '生成部署准备，实际服务仍需管理员受控应用；本页不会自动重启或启用。';
      if (controller.canPrepare) {
        action = controller.prepareRelease;
        label = '准备受控发布';
      }
    } else if (controller.releaseStatus?.confirmedOperation?.versionId ==
        controller.version?.id) {
      title = '继续真实联调';
      description = '请查看下方准备要求、手机步骤与当前验收记录。';
    } else {
      title = '核对发布与生效';
      description = '请在下方发布卡中提交明确版本，等待部署执行后核对全部身份实例。';
    }
    return Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Text(description,
          style: const TextStyle(fontSize: 16, height: 1.6, color: muted)),
      if (action != null && label != null)
        Padding(
            padding: const EdgeInsets.only(top: 16),
            child: FilledButton(
                onPressed: controller.busy ? null : action,
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                child: Text(label))),
    ]));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (controller.invalidated || !widget.isCurrent()) {
          return const Panel(child: Text('账号会话已变化，请重新打开本页。'));
        }
        final version = controller.version,
            settings = version?.settings,
            credentials = version?.credentials;
        final sms = credentials?.smsAccessKeyId == true &&
            credentials?.smsAccessKeySecret == true &&
            settings?.smsSignName.isNotEmpty == true &&
            settings?.smsTemplateCode.isNotEmpty == true;
        final wechat = credentials?.wechatAppSecret == true &&
            settings?.wechatAppId.isNotEmpty == true;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          PageHeading('短信与微信', '为家庭注册、找回账号和微信绑定准备服务。',
              action: OutlinedButton.icon(
                  onPressed: controller.busy ? null : controller.load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新状态'))),
          if (controller.busy)
            const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: LinearProgressIndicator()),
          if (controller.errorMessage != null)
            Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Notice(controller.errorMessage!, warning: true)),
          if (controller.message != null)
            Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Notice(controller.message!)),
          if (controller.status != null) ...[
            LayoutBuilder(builder: (context, box) {
              final width =
                  box.maxWidth >= 760 ? (box.maxWidth - 16) / 2 : box.maxWidth;
              return Wrap(spacing: 16, runSpacing: 16, children: [
                SizedBox(
                    width: width,
                    child: providerCard('短信服务', Icons.sms_outlined, sms,
                        '尚未验证实际送达。配置检查不能替代接收人收码。')),
                SizedBox(
                    width: width,
                    child: providerCard('微信登录', Icons.chat_bubble_outline,
                        wechat, '尚未验证真机授权。请使用正式签名家长端完成联调。')),
              ]);
            }),
            const SizedBox(height: 16),
          ],
          if (controller.status != null ||
              controller.needsReauthentication ||
              controller.pending != null)
            nextAction(),
          if (controller.status != null)
            Padding(
                padding: const EdgeInsets.only(top: 16),
                child: IdentityProviderReleasePanel(controller: controller)),
          if (version != null && widget.canManage)
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child: TextButton.icon(
                    onPressed: controller.canSave ? edit : null,
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('修改短信与微信配置'))),
          if (controller.validation != null)
            Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Panel(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('配置检查',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                      for (final check in controller.validation!.checks)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                                '${check.label}：${check.status == 'READY' ? '格式已核对' : '待处理'}\n${check.action}',
                                style: const TextStyle(
                                    fontSize: 16, height: 1.6))),
                    ]))),
          const SizedBox(height: 16),
          IdentityProviderAcceptancePanel(controller: controller),
          const SizedBox(height: 16),
          Panel(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('高级信息'),
                  children: [
                    ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('环境与版本'),
                        subtitle: Text(
                            '${controller.status?.environmentId ?? '待读取'} · ${version == null ? '尚未保存' : '配置版本 ${version.version}'}')),
                    ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('运行状态'),
                        subtitle: Text(
                            controller.releaseStatus?.activeOperation != null
                                ? '当前部署待确认。'
                                : controller.releaseStatus
                                            ?.confirmedOperation ==
                                        null
                                    ? '尚未确认全部身份实例已加载。'
                                    : '配置已加载，登录入口待验收。')),
                    const ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('购买状态'),
                        subtitle: Text('保持关闭；配置与清单不能代替收费发布验收。')),
                    if (controller.acceptance != null)
                      ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('联调记录'),
                          subtitle: SelectableText(controller.acceptance!.id)),
                  ])),
        ]);
      });
}
