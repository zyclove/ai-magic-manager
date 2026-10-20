import 'package:flutter/material.dart';
import '../core/family_identity_controller.dart';
import 'design.dart';

const _labels = {
  'REAL_SMS_DELIVERY': '真实短信发送与接收',
  'REAL_WECHAT_NATIVE_AUTH': '真机微信授权',
  'CHANGE_PHONE_E2E': '更换手机号',
  'RECOVER_PHONE_E2E': '已绑定微信找回账号',
  'BIND_WECHAT_E2E': '绑定微信',
  'UNBIND_WECHAT_E2E': '解绑微信',
  'IDENTITY_CONFLICTS': '手机号与微信冲突',
  'OLD_SESSION_REVOKED': '其他设备旧登录失效',
  'INTERRUPTION_RECOVERY': '取消与掉网后核对',
  'MYSQL_CONCURRENCY_ROLLBACK': 'MySQL 并发与回滚',
  'SIGNED_DEVICE_BUILD': '正式签名与安装包配置',
  'LOG_REDACTION': '真实链路不留敏感内容',
};

String _time(int value) {
  final date = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
}

String _nextAction(String? action) => switch (action) {
      'CONFIGURE' => '先填写短信与微信配置。',
      'CHECK_CONFIGURATION' => '先检查当前配置，补齐待处理项目。',
      'PUBLISH_CONFIGURATION' => '先受控发布当前配置。',
      'CHECK_RUNTIME' => '先核对全部身份实例是否已加载当前配置。',
      'REGISTER_RUN' => '当前版本已核对，可建立本次验收。',
      'PREPARE_PILOT' => '消费者入口仍关闭，需部署管理员准备独立受限成人试点。',
      _ => '尚未读取验收状态，请刷新后核对。',
    };

class IdentityProviderAcceptancePanel extends StatefulWidget {
  final FamilyIdentityController controller;
  const IdentityProviderAcceptancePanel({super.key, required this.controller});
  @override
  State<IdentityProviderAcceptancePanel> createState() =>
      _IdentityProviderAcceptancePanelState();
}

class _IdentityProviderAcceptancePanelState
    extends State<IdentityProviderAcceptancePanel> {
  FamilyIdentityController get controller => widget.controller;
  Route<bool>? _route;
  NavigatorState? _navigator;

  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
  }

  void _closeDialog() {
    final route = _route, navigator = _navigator;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator?.mounted == true && route?.isCurrent == true) {
        navigator!.pop(false);
      }
    });
  }

  void _changed() {
    if (!controller.active || !controller.canStartCurrentAcceptance) {
      _closeDialog();
    }
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    _closeDialog();
    super.dispose();
  }

  Future<void> _register() async {
    if (!controller.canStartCurrentAcceptance || _route != null) return;
    final snapshot = controller.acceptanceStatus!,
        version = controller.version!,
        navigator = Navigator.of(context, rootNavigator: true);
    bool matches() =>
        controller.canStartCurrentAcceptance &&
        controller.acceptanceStatus?.versionId == snapshot.versionId &&
        controller.acceptanceStatus?.confirmedOperationId ==
            snapshot.confirmedOperationId &&
        controller.acceptanceStatus?.runtimeRevision ==
            snapshot.runtimeRevision;
    final route = DialogRoute<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: const Text('建立本次验收'),
              content: SingleChildScrollView(
                  child: SizedBox(
                      width: 480,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '配置版本 ${version.version} · ${snapshot.environmentId}',
                              style:
                                  const TextStyle(fontSize: 16, height: 1.6)),
                          const SizedBox(height: 12),
                          const Text(
                              '自动使用已确认发布的安装包与身份扩展，记录有效期为 24 小时。仅登记待办，不发送短信、不发起微信授权；购买保持关闭。',
                              style: TextStyle(fontSize: 16, height: 1.6)),
                        ],
                      ))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () {
                      if (matches()) Navigator.pop(dialogContext, true);
                    },
                    child: const Text('确认建立')),
              ],
            ));
    _route = route;
    _navigator = navigator;
    try {
      final confirmed = await navigator.push<bool>(route);
      await route.completed;
      if (confirmed == true && mounted && matches()) {
        await controller.startCurrentAcceptance();
      }
    } finally {
      if (identical(_route, route)) {
        _route = null;
        _navigator = null;
      }
    }
  }

  Widget _step(String number, String title, Widget content) => Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$number · $title',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        content,
      ]));

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final status = controller.acceptanceStatus, run = status?.latestRun;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Panel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(
                    status == null
                        ? '真实联调验收'
                        : '真实联调验收 · ${status.passedCount}/${status.requiredCount}',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600)),
                _step(
                    '1',
                    '准备',
                    Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_nextAction(status?.nextAction),
                              style:
                                  const TextStyle(fontSize: 16, height: 1.6)),
                          if (status?.status == 'STALE')
                            const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text('原记录已过期或版本发生变化，请按当前版本重新核对。',
                                    style:
                                        TextStyle(fontSize: 16, height: 1.6))),
                          if (status != null)
                            for (final check in status.readinessChecks
                                .where((check) => check.status != 'READY'))
                              Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text('${check.label}：${check.action}',
                                      style: const TextStyle(
                                          fontSize: 16,
                                          height: 1.6,
                                          color: muted))),
                          if (controller.canStartCurrentAcceptance)
                            Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: FilledButton.icon(
                                    onPressed: _register,
                                    style: FilledButton.styleFrom(
                                        minimumSize: const Size(0, 48)),
                                    icon: const Icon(Icons.fact_check_outlined),
                                    label: const Text('建立本次验收'))),
                        ])),
                _step(
                    '2',
                    '手机完成',
                    const Text(
                        '准备好受限试点后，使用正式签名家长端。在登录页验证短信与微信；在“我的 → 账号与安全”验证换号、绑定和解绑；在“找回账号”验证原号不可用的恢复。验证码只在手机安全页面输入，微信授权由手机正常发起。',
                        style: TextStyle(
                            fontSize: 16, height: 1.6, color: muted))),
                _step(
                    '3',
                    '核对结果',
                    Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('本页读取服务端记录。登记清单、配置加载和测试回归均不能代替真实验收。',
                              style: TextStyle(
                                  fontSize: 16, height: 1.6, color: muted)),
                          if (run != null)
                            Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                    run.releaseOperationId == null
                                        ? '原记录尚未绑定已确认发布，请按当前版本重新建立。'
                                        : '本次记录仍待真实联调。有效至 ${_time(run.expiresAt!)}。',
                                    style: const TextStyle(
                                        fontSize: 16, height: 1.6))),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                              onPressed: controller.busy || !controller.active
                                  ? null
                                  : controller.load,
                              style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(0, 48)),
                              icon: const Icon(Icons.refresh),
                              label: const Text('刷新验收状态')),
                        ])),
                ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('查看 12 项验收要求',
                        style: TextStyle(fontSize: 16)),
                    children: [
                      for (final entry in _labels.entries)
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.radio_button_unchecked,
                                color: muted),
                            title: Text(entry.value,
                                style: const TextStyle(fontSize: 16)),
                            subtitle:
                                Text(status == null ? '尚未读取当前状态' : '待真实联调验证')),
                    ]),
                ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('最近验收记录', style: TextStyle(fontSize: 16)),
                    children: [
                      if (controller.acceptanceHistory != null &&
                          controller.acceptanceHistory!.isEmpty)
                        const ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('暂无记录')),
                      for (final item in controller.acceptanceHistory ?? [])
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('${_time(item.createdAt)} · 待真实联调'),
                            subtitle: Text(item.releaseOperationId == null
                                ? '未绑定发布的历史清单'
                                : '已绑定发布，不能代替验收通过')),
                      OutlinedButton(
                          onPressed: controller.busy ||
                                  !controller.active ||
                                  controller.needsReauthentication
                              ? null
                              : controller.loadAcceptanceHistory,
                          child: const Text('查询最近记录')),
                      const SizedBox(height: 12),
                    ]),
              ])),
          const SizedBox(height: 16),
          Panel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('收费开放检查',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                    status == null
                        ? '尚未读取收费检查结果，购买保持关闭。'
                        : '购买保持关闭，请先补齐以下交付条件。',
                    style: const TextStyle(fontSize: 16, height: 1.6)),
                if (status != null)
                  for (final check in status.salesChecks)
                    Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                            '${check.label}：${check.status == 'READY' ? '已核对准备条件' : '待完成'}\n${check.action}',
                            style: const TextStyle(
                                fontSize: 16, height: 1.6, color: muted))),
              ])),
        ]);
      });
}
