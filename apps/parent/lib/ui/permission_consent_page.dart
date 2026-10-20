import 'operation_result_terminal_panel.dart';
import 'package:flutter/material.dart';
import 'package:usage_reporting/usage_reporting.dart';
import '../core/observation_settings.dart' show validConsentReason;
import '../core/permission_consent.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';

/// Independent consent with explicit review. MFA never implicitly enables other observations.
class PermissionConsentPage extends StatefulWidget {
  final ParentSession session;
  final UsageReportTarget target;
  final PermissionChangeStore? store;
  const PermissionConsentPage(
      {super.key, required this.session, required this.target, this.store});
  @override
  State<PermissionConsentPage> createState() => _PermissionConsentPageState();
}

class _PermissionConsentPageState extends State<PermissionConsentPage>
    with WidgetsBindingObserver {
  late final String tenant, actor, role;
  late final ParentPermissionConsent controller;
  final reason = TextEditingController();
  bool foreground = true, enabled = false, confirmed = false, checked = false;
  int? editingVersion;
  String? validation;
  bool get current =>
      mounted &&
      !_operationOwnerLost &&
      _operationIdentity.current &&
      widget.session.canDecide &&
      widget.session.tenant?['id'] == tenant &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;
  bool _operationOwnerLost = false;
  late final ParentOperationIdentity _operationIdentity;
  @override
  void deactivate() {
    _operationOwnerLost = true;
    _operationIdentity.revoke();
    super.deactivate();
  }

  @override
  void initState() {
    super.initState();
    _operationIdentity = ParentOperationIdentity(widget.session, onRevoked: _changed);
    tenant = widget.session.tenant!['id'];
    actor = widget.session.profile!['subject'];
    role = widget.session.role;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    controller = ParentPermissionConsent(
        api: _operationIdentity.scopedApi(widget.session.api),
        store: widget.store ?? PermissionChangeStore(),
        tenant: tenant,
        actor: actor,
        target: widget.target,
        isCurrent: () => current && _operationIdentity.dispatchable,
        foreground: () => foreground,
        reauthenticate: _operationIdentity.reauthenticate);
    widget.session.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    controller.load();
  }

  void _changed() {
    if (!mounted || current) return;
    _operationOwnerLost = true;
    controller.hide();
    reason.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      controller.hide();
      confirmed = false;
      checked = false;
    }
    if (mounted) setState(() {});
  }

  Future<void> reload() async {
    editingVersion = null;
    confirmed = false;
    checked = false;
    validation = null;
    reason.clear();
    await controller.load();
  }

  Future<void> submit() async {
    if (!current || !foreground) return;
    if (!confirmed || !validConsentReason(reason.text)) {
      setState(() => validation = '请填写用途或撤回原因，并确认采集范围。');
      return;
    }
    FocusScope.of(context).unfocus();
    await controller.submit(enabled: enabled, reason: reason.text);
  }

  Future<void> _authenticateAndRead() async {
    if (!current || !foreground || controller.busy || widget.session.busy) {
      return;
    }
    if (!await _operationIdentity.reauthenticate() || !current || !foreground) {
      return;
    }
    if (controller.pending != null) {
      await controller.query();
    } else {
      await reload();
    }
  }

  @override
  void dispose() {
    _operationIdentity.dispose();
    widget.session.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    reason.dispose();
    super.dispose();
  }

  String state(bool enabled) => enabled ? '允许观察' : '已关闭';
  Widget card(String title, bool enabled, int version) => Card(
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('${state(enabled)} · 授权版本 $version'),
          ])));
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (controller.resultTerminal != null) {
          return parentResultTerminalPage(context, title: '权限观察核对', operation: controller,
              onViewCurrent: reload,
              currentRecordBuilder: (_) => controller.settings == null
                  ? const Text('当前授权暂时无法读取，请刷新或核对审计。')
                  : card('当前权限观察授权', controller.settings!.enabled, controller.settings!.version));
        }
        final now = controller.settings,
            original = controller.committed,
            pending = controller.pending;
        if (now != null && pending == null && editingVersion != now.version) {
          editingVersion = now.version;
          enabled = now.enabled;
        }
        final editable = current &&
            foreground &&
            controller.loaded &&
            now != null &&
            pending == null &&
            !controller.busy;
        return PopScope(
            canPop: !controller.busy,
            child: Scaffold(
                appBar: AppBar(title: const Text('权限观察授权')),
                body: !current || !foreground
                    ? const Center(child: Text('授权内容已隐藏，返回后请重新读取。'))
                    : Center(
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 680),
                            child: ListView(
                                padding: const EdgeInsets.all(20),
                                children: [
                                  Text(widget.target.displayName,
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall),
                                  const SizedBox(height: 12),
                                  const Text(
                                      '仅观察所选应用声明的系统权限及设备报告的授权状态。不采集相机画面、联系人、位置或应用内容，也不会代替系统授予或撤销权限。'),
                                  const SizedBox(height: 16),
                                  if (controller.busy)
                                    const LinearProgressIndicator(),
                                  if (controller.error != null)
                                    Semantics(
                                        liveRegion: true,
                                        child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                                vertical: 12),
                                            child:
                                                Text('${controller.error}'))),
                                  if (controller.error is ParentApiException &&
                                      (controller.error as ParentApiException)
                                              .status ==
                                          401)
                                    TextButton.icon(
                                        onPressed: controller.busy ||
                                                widget.session.busy
                                            ? null
                                            : _authenticateAndRead,
                                        icon: const Icon(
                                            Icons.verified_user_outlined),
                                        label: const Text('重新安全验证并核对')),
                                  if (now != null)
                                    card('当前授权', now.enabled, now.version),
                                  ParentKnownOperationReceipt(operation: controller),
                        if (pending == null) ...[
                                    if (now == null)
                                      OutlinedButton.icon(
                                          onPressed:
                                              controller.busy ? null : reload,
                                          icon: const Icon(Icons.refresh),
                                          label: const Text('重新读取授权')),
                                    if (now != null) ...[
                                      SwitchListTile(
                                          contentPadding: EdgeInsets.zero,
                                          title: const Text('允许观察应用权限'),
                                          subtitle: const Text(
                                              '独立于应用清单与使用摘要授权，可随时关闭。'),
                                          value: enabled,
                                          onChanged: editable
                                              ? (v) => setState(() {
                                                    enabled = v;
                                                    confirmed = false;
                                                  })
                                              : null),
                                      TextField(
                                          controller: reason,
                                          enabled: editable,
                                          maxLength: 300,
                                          minLines: 1,
                                          maxLines: 3,
                                          decoration: const InputDecoration(
                                              labelText: '用途或撤回原因',
                                              hintText: '例如：核对学习应用的麦克风权限')),
                                      Text(
                                          '本次变更：${state(now.enabled)} → ${state(enabled)}'),
                                      const SizedBox(height: 12),
                                      const Text(
                                          '保存后会清空服务端已有的权限快照。允许观察时，需等待设备按新授权上报；关闭后，离线设备将在下次联网时核对并清理待发数据。'),
                                      CheckboxListTile(
                                          contentPadding: EdgeInsets.zero,
                                          title: const Text('我已确认采集范围和变更影响'),
                                          value: confirmed,
                                          onChanged: editable
                                              ? (v) => setState(() {
                                                    confirmed = v == true;
                                                    validation = null;
                                                  })
                                              : null),
                                      if (validation != null)
                                        Semantics(
                                            liveRegion: true,
                                            child: Text(validation!)),
                                      FilledButton.icon(
                                          onPressed:
                                              editable && enabled != now.enabled
                                                  ? submit
                                                  : null,
                                          icon: const Icon(
                                              Icons.verified_user_outlined),
                                          label: const Text('确认并进行安全验证')),
                                    ],
                                  ] else ...[
                                    card(
                                        '原提交 · 待核对',
                                        pending['body']['enabled'],
                                        pending['body']['version']),
                                    if (original != null)
                                      card('原操作已提交（历史结果）', original.enabled,
                                          original.version),
                                    const Text(
                                        '只查询原结果，不会重复提交授权。历史结果与当前授权可能不同。'),
                                    ExpansionTile(
                                        title: const Text('查看原操作详情'),
                                        children: [
                                          ListTile(
                                              title: Text(
                                                  '原因：${pending['body']['reason']}'),
                                              subtitle: SelectableText(
                                                  '操作编号：${pending['requestId']}')),
                                        ]),
                                    OutlinedButton.icon(
                                        onPressed: controller.busy
                                            ? null
                                            : () {
                                                checked = false;
                                                controller.query();
                                              },
                                        icon: const Icon(Icons.manage_search),
                                        label: const Text('核对原操作结果')),
                                    if (controller.queried) ...[
                                      CheckboxListTile(
                                          contentPadding: EdgeInsets.zero,
                                          value: checked,
                                          title: const Text('我已核对当前授权与原结果'),
                                          subtitle: const Text(
                                              '清除本机记录不会撤销授权。结果查不到不代表没有提交，需另行核对审计。'),
                                          onChanged: controller.busy
                                              ? null
                                              : (v) => setState(
                                                  () => checked = v == true)),
                                      FilledButton(
                                          onPressed: controller.busy || !checked
                                              ? null
                                              : () async {
                                                  await controller
                                                      .acknowledge();
                                                  if (current &&
                                                      foreground &&
                                                      controller.pending ==
                                                          null) await reload();
                                                },
                                          child: const Text('完成核对')),
                                    ],
                                  ],
                                ])))));
      });
}
