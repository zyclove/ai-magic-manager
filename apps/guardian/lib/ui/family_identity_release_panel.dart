import 'package:flutter/material.dart';
import '../core/family_identity_controller.dart';
import '../core/family_identity_repository.dart';
import 'design.dart';

String identityReleaseStateLabel(String state) => switch (state) {
      'WAITING_EXECUTOR' => '等待部署执行',
      'CLAIMED' => '部署处理中，等待实例核对',
      'EXECUTION_UNKNOWN' => '部署结果待核对',
      'APPLIED_CLOSED' => '配置已加载，登录入口待验收',
      'CANCELLED' => '发布已取消',
      _ => '尚未确认生效',
    };

String _time(int value) {
  final date = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
}

class IdentityProviderReleasePanel extends StatefulWidget {
  final FamilyIdentityController controller;
  const IdentityProviderReleasePanel({super.key, required this.controller});
  @override
  State<IdentityProviderReleasePanel> createState() =>
      _IdentityProviderReleasePanelState();
}

class _IdentityProviderReleasePanelState
    extends State<IdentityProviderReleasePanel> {
  bool dialogOpen = false;
  Route<dynamic>? _dialogRoute;
  NavigatorState? _dialogNavigator;
  FamilyIdentityController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_scopeChanged);
  }

  void _closeDialog() {
    final route = _dialogRoute, navigator = _dialogNavigator;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator?.mounted == true && route?.isCurrent == true) {
        navigator!.pop();
      }
    });
  }

  void _scopeChanged() {
    if (!controller.active) _closeDialog();
  }

  Future<T?> _show<T>(
      {required BuildContext context, required WidgetBuilder builder}) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<T>(context: context, builder: builder);
    _dialogRoute = route;
    _dialogNavigator = navigator;
    try {
      final result = await navigator.push<T>(route);
      await route.completed;
      return result;
    } finally {
      if (identical(_dialogRoute, route)) {
        _dialogRoute = null;
        _dialogNavigator = null;
      }
    }
  }

  @override
  void dispose() {
    controller.removeListener(_scopeChanged);
    _closeDialog();
    super.dispose();
  }

  Future<void> publish() async {
    if (!controller.canPublishRelease || dialogOpen) return;
    final version = controller.version!,
        release = controller.releaseStatus!,
        preparation = controller.preparation!;
    dialogOpen = true;
    final form = GlobalKey<FormState>(),
        jar = TextEditingController(),
        apk = TextEditingController();
    try {
      final confirmed = await _show<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                  title: const Text('确认受控发布'),
                  content: SizedBox(
                      width: 520,
                      child: SingleChildScrollView(
                          child: Form(
                              key: form,
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        '目标：配置版本 ${version.version}\n环境：${release.environmentId}',
                                        style: const TextStyle(
                                            fontSize: 16, height: 1.6)),
                                    const SizedBox(height: 16),
                                    const Text(
                                        '登记后由受限部署执行器应用，再核对全部身份实例。短信和微信登录入口保持关闭，已有真实验收不会自动通过。',
                                        style: TextStyle(
                                            fontSize: 16, height: 1.6)),
                                    const SizedBox(height: 16),
                                    TextFormField(
                                        controller: jar,
                                        decoration: const InputDecoration(
                                            labelText: '身份扩展产物 SHA-256'),
                                        maxLength: 64,
                                        validator: (value) =>
                                            isIdentityProviderDigest(value
                                                        ?.trim()
                                                        .toLowerCase() ??
                                                    '')
                                                ? null
                                                : '请填写 64 位十六进制摘要'),
                                    const SizedBox(height: 16),
                                    TextFormField(
                                        controller: apk,
                                        decoration: const InputDecoration(
                                            labelText: '正式家长安装包 SHA-256'),
                                        maxLength: 64,
                                        validator: (value) =>
                                            isIdentityProviderDigest(value
                                                        ?.trim()
                                                        .toLowerCase() ??
                                                    '')
                                                ? null
                                                : '请填写 64 位十六进制摘要'),
                                  ])))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('暂不发布')),
                    FilledButton(
                        onPressed: () {
                          if (controller.canPublishRelease &&
                              controller.version?.id == version.id &&
                              controller.preparation?.id == preparation.id &&
                              controller.releaseStatus?.runtimeRevision ==
                                  release.runtimeRevision &&
                              (form.currentState?.validate() ?? false)) {
                            Navigator.pop(dialogContext, true);
                          }
                        },
                        child: const Text('确认发布此版本')),
                  ]));
      if (confirmed == true &&
          controller.canPublishRelease &&
          controller.version?.id == version.id &&
          controller.preparation?.id == preparation.id &&
          controller.releaseStatus?.runtimeRevision ==
              release.runtimeRevision) {
        await controller.publish(
            jar.text.trim().toLowerCase(), apk.text.trim().toLowerCase());
      }
    } finally {
      jar.dispose();
      apk.dispose();
      dialogOpen = false;
    }
  }

  Future<void> rollback() async {
    if (!controller.canRollbackRelease || dialogOpen) return;
    final release = controller.releaseStatus!;
    dialogOpen = true;
    IdentityProviderReleaseTarget? selected;
    try {
      selected = await _show<IdentityProviderReleaseTarget>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                  title: const Text('选择已确认的历史配置'),
                  content: SizedBox(
                      width: 520,
                      child: SingleChildScrollView(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                        const Text('只显示服务端允许回退且曾确认加载的版本。选择后先查看影响。',
                            style: TextStyle(fontSize: 16, height: 1.6)),
                        const SizedBox(height: 16),
                        for (final target in release.rollbackTargets)
                          ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text('确认于 ${_time(target.confirmedAt)}'),
                              subtitle: Text(
                                  '配置 ${target.versionId.substring(0, 8)}'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () =>
                                  Navigator.pop(dialogContext, target)),
                      ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('取消'))
                  ]));
      if (selected == null || !mounted || !controller.canRollbackRelease) {
        return;
      }
      final target = selected;
      final confirmed = await _show<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                  title: const Text('回退影响预览'),
                  content: SizedBox(
                      width: 520,
                      child: SingleChildScrollView(
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(
                                '环境：${release.environmentId}\n目标：${target.versionId}\n上次确认：${_time(target.confirmedAt)}',
                                style:
                                    const TextStyle(fontSize: 16, height: 1.6)),
                            const SizedBox(height: 16),
                            const Text(
                                '将创建一次新的受控回退操作，恢复目标版本的短信与微信配置。当前草稿保留，登录入口保持关闭；部署执行后仍需核对全部身份实例。',
                                style: TextStyle(fontSize: 16, height: 1.6)),
                          ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () {
                          if (controller.canRollbackRelease &&
                              controller.releaseStatus?.runtimeRevision ==
                                  release.runtimeRevision) {
                            Navigator.pop(dialogContext, true);
                          }
                        },
                        child: const Text('确认回退此版本')),
                  ]));
      if (confirmed == true &&
          controller.canRollbackRelease &&
          controller.releaseStatus?.runtimeRevision ==
              release.runtimeRevision) {
        await controller.rollback(target);
      }
    } finally {
      dialogOpen = false;
    }
  }

  Future<void> cancelRelease() async {
    if (!controller.canCancelRelease || dialogOpen) return;
    final operation = controller.releaseStatus!.activeOperation!,
        revision = controller.releaseStatus!.runtimeRevision;
    dialogOpen = true;
    try {
      final confirmed = await _show<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                  title: const Text('取消尚未执行的任务'),
                  content: const Text(
                      '此任务尚未被部署执行器领取。取消后保留当前已确认配置；已经开始执行的任务不能在这里取消。',
                      style: TextStyle(fontSize: 16, height: 1.6)),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('继续等待')),
                    FilledButton(
                        onPressed: () {
                          if (controller.canCancelRelease &&
                              controller.releaseStatus?.activeOperation?.id ==
                                  operation.id &&
                              controller.releaseStatus?.runtimeRevision ==
                                  revision) {
                            Navigator.pop(dialogContext, true);
                          }
                        },
                        child: const Text('确认取消任务')),
                  ]));
      if (confirmed == true &&
          controller.canCancelRelease &&
          controller.releaseStatus?.activeOperation?.id == operation.id &&
          controller.releaseStatus?.runtimeRevision == revision) {
        await controller.cancelRelease();
      }
    } finally {
      dialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = controller.releaseStatus,
        active = status?.activeOperation,
        confirmed = status?.confirmedOperation,
        check = controller.runtimeCheck;
    return Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('发布与生效',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      Text(
          status == null
              ? '发布状态暂未核对'
              : active != null
                  ? identityReleaseStateLabel(active.state)
                  : confirmed != null
                      ? '配置已加载，登录入口待验收'
                      : '尚未确认生效',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Text(
          status == null
              ? '请刷新状态；无法核对时不能发布或回退。'
              : active?.state == 'EXECUTION_UNKNOWN'
                  ? '原部署结果不确定，先核对全部实例；当前不能创建其他发布或回退。'
                  : active != null
                      ? '当前部署待确认。${confirmed == null ? '' : '最近确认时间：${_time(confirmed.confirmedAt!)}。'}请等待执行后核对全部身份实例。'
                      : confirmed != null
                          ? '最近确认时间：${_time(confirmed.confirmedAt!)}。配置加载确认不代表短信送达、微信授权或收费验收通过。'
                          : '发布请求、部署执行和实例确认分步完成；真实联调和购买保持关闭。',
          style: const TextStyle(fontSize: 16, height: 1.6, color: muted)),
      if (status != null && !status.executorReady)
        const Padding(
            padding: EdgeInsets.only(top: 12),
            child:
                Text('部署执行器尚未准备好，请联系部署管理员。', style: TextStyle(fontSize: 16))),
      if (active != null && !status!.observationReady)
        const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('实例核对尚未准备好，请联系部署管理员。', style: TextStyle(fontSize: 16))),
      if (controller.canCheckRuntime)
        Padding(
            padding: const EdgeInsets.only(top: 16),
            child: FilledButton.icon(
                onPressed: controller.checkReleaseRuntime,
                icon: const Icon(Icons.verified_outlined),
                label: const Text('核对生效状态'))),
      if (controller.canPublishRelease)
        Padding(
            padding: const EdgeInsets.only(top: 16),
            child: FilledButton.icon(
                onPressed: publish,
                icon: const Icon(Icons.publish_outlined),
                label: const Text('发布此配置'))),
      if (controller.canRollbackRelease)
        Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton.icon(
                onPressed: rollback,
                icon: const Icon(Icons.history),
                label: const Text('回退到已确认版本'))),
      if (controller.canCancelRelease)
        Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TextButton(
                onPressed: cancelRelease, child: const Text('取消尚未执行的任务'))),
      if (check != null) ...[
        const SizedBox(height: 16),
        Text(
            check.state == 'CONFIRMED'
                ? '全部身份实例已核对'
                : check.state == 'MISMATCH'
                    ? '实例配置不一致，需检查部署'
                    : check.state == 'CHECKING'
                        ? '实例核对进行中'
                        : '部分实例暂时无法核对',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        for (final instance in check.instances)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  '${instance.instanceId}：${instance.state == 'CONFIRMED' ? '配置已核对' : instance.state == 'MISMATCH' ? '配置不一致' : '暂不可达'}',
                  style: const TextStyle(fontSize: 16, height: 1.6))),
      ],
      if (active != null || confirmed != null)
        ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('发布详情'),
            children: [
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('最近确认配置'),
                  subtitle: SelectableText(confirmed?.versionId ?? '尚未确认')),
              if (active != null)
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title:
                        Text(active.kind == 'ROLLBACK' ? '本次回退操作' : '本次发布操作'),
                    subtitle: SelectableText(
                        '${active.id}\n目标配置：${active.versionId}')),
            ]),
    ]));
  }
}
