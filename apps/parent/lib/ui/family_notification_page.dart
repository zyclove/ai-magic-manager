import 'package:flutter/material.dart';
import '../core/family_notifications.dart';
import '../core/family.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import 'family_workspace.dart';

class FamilyNotificationEntry extends StatelessWidget {
  final ParentSession session;
  final FamilyNotificationCoordinator coordinator;
  const FamilyNotificationEntry(
      {super.key, required this.session, required this.coordinator});
  @override
  Widget build(BuildContext context) => Card(
      child: ListTile(
          leading: const Icon(Icons.notifications_outlined),
          title: const Text('消息提醒'),
          subtitle: const Text('申请、设备异常与到期提醒'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => FamilyNotificationPage(
                  session: session, coordinator: coordinator)))));
}

class FamilyNotificationPage extends StatefulWidget {
  final ParentSession session;
  final FamilyNotificationCoordinator coordinator;
  const FamilyNotificationPage(
      {super.key, required this.session, required this.coordinator});
  @override
  State<FamilyNotificationPage> createState() => _FamilyNotificationPageState();
}

class _FamilyNotificationPageState extends State<FamilyNotificationPage>
    with FamilyScope, WidgetsBindingObserver {
  @override
  ParentSession get session => widget.session;
  FamilyNotificationCoordinator get notices => widget.coordinator;
  bool localBusy = false, foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    notices.addListener(changed);
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!notices.loaded && foreground) run(notices.load);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) {
      setState(() => foreground = state == AppLifecycleState.resumed);
    }
  }

  @override
  void dispose() {
    notices.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (!current || !foreground || localBusy) return;
    setState(() => localBusy = true);
    try {
      await action();
    } catch (_) {
      /* Coordinator exposes a redacted, recoverable error. */
    } finally {
      if (mounted) setState(() => localBusy = false);
    }
  }

  String errorText(Object value) => value is ParentApiException
      ? switch (value.code) {
          'PUSH_NOT_CONFIGURED' => '提醒服务尚未开放，请稍后重新核对。',
          'PUSH_PERMISSION_REQUIRED' => '系统通知尚未允许，请在系统设置中打开此应用的通知后重新核对。',
          'PUSH_PREVIOUS_ACCOUNT_REQUIRED' => '上个账号的提醒注销还需核对。请使用原账号登录后重新读取。',
          'PUSH_REGISTRATION_PENDING' => '上次开启或关闭还未核对完成，请重新读取原进度。',
          _ => familyError(value)
        }
      : '暂未完成，请检查系统设置或网络后重新核对。';
  @override
  Widget build(BuildContext context) {
    final prefs = notices.preferences, busy = localBusy || notices.busy;
    final configured = notices.nativeState?.configured == true &&
        notices.readiness?.providerConfigured == true &&
        notices.readiness?.workerEnabled == true;
    final enabled = current && foreground && !busy && notices.loaded;
    Widget preference(String title, String description, bool value,
            FamilyNotificationPreferences next) =>
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(title),
            subtitle: Text(description),
            value: value,
            onChanged: enabled
                ? (_) => run(() => notices.savePreferences(next))
                : null);
    return Scaffold(
        appBar: AppBar(title: const Text('消息提醒')),
        body: !current
            ? const Center(child: Text('当前家庭或权限已变化，请返回重新打开。'))
            : !foreground
                ? const Center(child: Text('返回后会重新核对提醒状态。'))
                : RefreshIndicator(
                    onRefresh: () => run(notices.load),
                    child: ListView(
                        padding: const EdgeInsets.all(20),
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          if (busy) const LinearProgressIndicator(),
                          if (notices.error != null)
                            FamilyNotice(errorText(notices.error!),
                                error: true),
                          FamilyPanel(
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                const Icon(Icons.notifications_active_outlined,
                                    size: 32, color: familyInk),
                                const SizedBox(height: 12),
                                Text(
                                    notices.deviceRegistered
                                        ? '此手机已登记提醒'
                                        : '这台手机的提醒',
                                    style:
                                        Theme.of(context).textTheme.titleLarge),
                                const SizedBox(height: 8),
                                const Text('锁屏只显示“家庭提醒”，打开后再查看家庭消息。'),
                                if (notices.loaded && !configured)
                                  const FamilyNotice(
                                      '提醒服务尚未开放。你仍可在应用内处理申请和查看设备状态。'),
                                if (notices.revocationPending)
                                  const FamilyNotice(
                                      '本机已停止显示提醒，服务器注销仍待核对。请联网后重新读取。'),
                                if (notices.deviceRegistered &&
                                    prefs?.enabled == false)
                                  const FamilyNotice(
                                      '此手机已允许提醒，请打开下方总开关并选择需要的内容。'),
                                const SizedBox(height: 12),
                                if (notices.deviceRegistered)
                                  OutlinedButton(
                                      onPressed: enabled
                                          ? () => run(notices.disableOnDevice)
                                          : null,
                                      child: const Text('关闭此手机提醒'))
                                else
                                  FilledButton(
                                      onPressed: enabled &&
                                              configured &&
                                              !notices.revocationPending
                                          ? () => run(notices.enableOnDevice)
                                          : null,
                                      child: const Text('在此手机开启提醒')),
                                TextButton(
                                    onPressed: current && foreground && !busy
                                        ? () => run(notices.load)
                                        : null,
                                    child: const Text('重新核对状态')),
                              ])),
                          if (prefs != null)
                            FamilyPanel(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text('提醒内容',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge),
                                  preference(
                                      '接收家庭提醒',
                                      '先开启总开关，再选择需要的内容。',
                                      prefs.enabled,
                                      prefs.copyWith(enabled: !prefs.enabled)),
                                  preference(
                                      '孩子的申请',
                                      '有申请或审批结果时提醒。',
                                      prefs.requests,
                                      prefs.copyWith(
                                          requests: !prefs.requests)),
                                  preference(
                                      '设备需要检查',
                                      '连接中断或运行权限异常时提醒。',
                                      prefs.deviceAttention,
                                      prefs.copyWith(
                                          deviceAttention:
                                              !prefs.deviceAttention)),
                                  preference(
                                      '会员与作息到期',
                                      '会员到期、选择保留设备或作息临期提醒。',
                                      prefs.ruleExpiry,
                                      prefs.copyWith(
                                          ruleExpiry: !prefs.ruleExpiry)),
                                  if (prefs.enabled &&
                                      !prefs.requests &&
                                      !prefs.deviceAttention &&
                                      !prefs.ruleExpiry)
                                    const FamilyNotice('请选择至少一类提醒。'),
                                ])),
                          const FamilyNotice(
                              '网络、系统省电或通知权限可能延迟提醒。必要操作仍可直接在应用中完成。'),
                        ])));
  }
}
