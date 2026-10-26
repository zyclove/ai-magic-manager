import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/labels.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/owned_dialog_route.dart';
import 'device_subflow_scope.dart';

const _unavailableSettings = Panel(
    child: EmptyView('工作空间或权限已变化',
        '已隐藏旧设置，请重新打开当前工作空间的设置页。'));

class SettingsPage extends StatefulWidget {
  final Session session;
  final Future<void> Function() onCreateWorkspace, onAcceptInvitation;

  const SettingsPage(
      {super.key,
      required this.session,
      required this.onCreateWorkspace,
      required this.onAcceptInvitation});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Session sessionOwner;
  late final DeviceSubflowScope scope;
  ValueNotifier<bool>? editorLifetime;
  ModalRoute<dynamic>? owner;
  bool active = true, busy = false;
  Object? error;

  bool get sameContext =>
      mounted &&
      active &&
      identical(widget.session, sessionOwner) &&
      sessionOwner.tenant != null &&
      sessionOwner.canOpen('settings');
  bool get current =>
      sameContext &&
      scope.current &&
      (owner == null || owner!.isActive) &&
      (owner is! OwnedDialogRoute<dynamic> ||
          (owner as OwnedDialogRoute<dynamic>).available);
  bool get interactive =>
      current &&
      !busy &&
      (owner == null || (owner!.isActive && owner!.isCurrent));

  @override
  void initState() {
    super.initState();
    sessionOwner = widget.session;
    scope = DeviceSubflowScope(sessionOwner, permitted: () => sameContext);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    owner ??= ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) retire();
  }

  void retire() {
    if (!active) return;
    active = false;
    scope.dispose();
    final lifetime = editorLifetime;
    if (lifetime == null) return;
    // The form owns this notifier until its route is completely finished.
    // Notify after the current build, including a form not yet built by push.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (identical(editorLifetime, lifetime)) lifetime.value = false;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void deactivate() {
    retire();
    super.deactivate();
  }

  @override
  void dispose() {
    retire();
    super.dispose();
  }

  Future<void> perform(FutureOr<void> Function() callback) async {
    if (!interactive) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await callback();
    } catch (failure) {
      // A write rejection does not revoke otherwise readable settings.
      if (current) setState(() => error = failure);
    } finally {
      if (mounted && active) setState(() => busy = false);
    }
  }

  Future<void> edit() async {
    if (!interactive || !sessionOwner.canManage) return;
    await perform(() async {
      final tenant = Map<String, dynamic>.from(sessionOwner.tenant!);
      final root = sessionOwner.root;
      final version = tenant['version'];
      if (version is! int || version < 0) {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
      final lifetime = ValueNotifier(true);
      final editorScope = DeviceSubflowScope(sessionOwner,
          permitted: () => current && sessionOwner.canManage && lifetime.value);
      editorLifetime = lifetime;
      bool editable() => editorScope.current;
      try {
        final result = await formDialog(context,
            title: '编辑工作空间',
            accessChanges: Listenable.merge([editorScope, lifetime]),
            hasAccess: editable,
            fields: const [
              FieldSpec('name', '名称'),
              FieldSpec.timeZone('timeZone', '时区'),
            ],
            initial: tenant,
            onSubmit: (values) async => await editorScope.api
                .send('PATCH', root, body: values, version: version) as Json,
            reauth: () {
              if (editable()) sessionOwner.login(stepUp: true);
            });
        if (result != null && editable()) await sessionOwner.loadTenants();
      } finally {
        if (identical(editorLifetime, lifetime)) editorLifetime = null;
        editorScope.dispose();
        lifetime.dispose();
      }
    });
  }

  Future<void> createWorkspace() async {
    if (!interactive || sessionOwner.profile?['canCreateTenant'] != true) return;
    await perform(widget.onCreateWorkspace);
  }

  Future<void> acceptInvitation() => perform(widget.onAcceptInvitation);
  Future<void> account() => perform(sessionOwner.account);
  Future<void> reauthenticate() => perform(() => sessionOwner.login(stepUp: true));
  Future<void> logout() => perform(sessionOwner.logout);

  @override
  Widget build(BuildContext context) => !active ? _unavailableSettings : AnimatedBuilder(
      animation: Listenable.merge([sessionOwner, scope]),
      builder: (context, _) {
        if (!current) {
          return _unavailableSettings;
        }
        final s = sessionOwner;
        final tenant = s.tenant!;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const PageHeading('设置', '查看工作空间资料并管理账户安全。'),
          if (busy && (owner?.isCurrent ?? true)) ...[
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 12),
          ],
          if (error != null) ...[
            Panel(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('操作结果待核对，请先检查当前状态，再重新操作。'),
                  const SizedBox(height: 8),
                  FailureView(error!),
                ])),
            const SizedBox(height: 20),
          ],
          Panel(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('工作空间',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 20),
                _setting('名称', tenant['name']),
                _setting('类型', label(tenant['kind'])),
                _setting('时区', tenant['timeZone']),
                _setting('我的角色', label(s.role)),
                const SizedBox(height: 12),
                Wrap(spacing: 12, runSpacing: 10, children: [
                  if (s.canManage)
                    OutlinedButton.icon(
                        onPressed: interactive ? edit : null,
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('编辑资料')),
                  if (s.profile?['canCreateTenant'] == true)
                    OutlinedButton(
                        onPressed: interactive ? createWorkspace : null,
                        child: const Text('新建工作空间')),
                  TextButton(
                      onPressed: interactive ? acceptInvitation : null,
                      child: const Text('接受邀请')),
                ]),
              ])),
          const SizedBox(height: 20),
          Panel(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('账户安全',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 16),
                _setting('登录邮箱', s.profile?['email'] ?? s.displayName),
                const Notice('邀请成员、发布策略、设备退出等操作需要近期多因素认证。'
                    '先在账户中心绑定验证器，再重新安全验证。'),
                const SizedBox(height: 18),
                Wrap(spacing: 12, runSpacing: 10, children: [
                  OutlinedButton.icon(
                      onPressed: interactive ? account : null,
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('账户与验证器')),
                  FilledButton(
                      onPressed: interactive ? reauthenticate : null,
                      child: const Text('重新安全验证')),
                  TextButton(
                      onPressed: interactive ? logout : null,
                      child: const Text('退出登录')),
                ]),
              ])),
          const SizedBox(height: 20),
          const Panel(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('能力说明',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                SizedBox(height: 12),
                Text('管理端连接真实业务 API，配置与审计保存在数据库中。'
                    '设备系统执行、第三方通知、支付及模型服务需完成相应接入后开放。',
                    style: TextStyle(color: muted, height: 1.8)),
              ])),
        ]);
      });
}

Widget _setting(String key, Object? value) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 110,
          child: Text(key, style: const TextStyle(color: muted))),
      Expanded(child: SelectableText(
          value is String && value.isNotEmpty ? value : '未提供')),
    ]));
