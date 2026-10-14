import 'package:flutter/material.dart';
import 'package:usage_reporting/usage_reporting.dart';
import '../core/observation_settings.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';

Future<void> openParentObservation(
    BuildContext context, ParentSession session, Json device) async {
  if (!session.canDecide ||
      !session.authenticated ||
      session.tenant == null ||
      device['state'] != 'ACTIVE') return;
  if (['id', 'registrationId', 'subjectId', 'platform', 'displayName']
      .any((key) => device[key] is! String)) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('设备注册信息不完整，请刷新后重试。')));
    return;
  }
  final target = UsageReportTarget(device['id'], device['registrationId'],
      device['subjectId'], device['displayName'],
      platform: device['platform']);
  if (!target.valid) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('设备注册信息已变化，请重新选择。')));
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ParentObservationPage(session: session, target: target)));
}

/// 手机整页编辑，保留原范围与变更影响；不把云端同意显示成系统许可。
class ParentObservationPage extends StatefulWidget {
  final ParentSession session;
  final UsageReportTarget target;
  final ObservationChangeStore? store;
  const ParentObservationPage(
      {super.key, required this.session, required this.target, this.store});
  @override
  State<ParentObservationPage> createState() => _ParentObservationPageState();
}

class _ParentObservationPageState extends State<ParentObservationPage>
    with WidgetsBindingObserver {
  late final String tenant, actor, role;
  late final ParentObservationController controller;
  final reason = TextEditingController();
  final form = GlobalKey<FormState>();
  bool inventory = false,
      usage = false,
      acknowledged = false,
      foreground = true;
  int? editingVersion;
  String? validation;
  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.tenant?['id'] == tenant &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role &&
      widget.session.canDecide;
  @override
  void initState() {
    super.initState();
    tenant = widget.session.tenant!['id'];
    actor = widget.session.profile!['subject'];
    role = widget.session.role;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    controller = ParentObservationController(
        api: widget.session.api,
        store: widget.store ?? ObservationChangeStore(),
        tenant: tenant,
        actor: actor,
        target: widget.target,
        isCurrent: () => current,
        foreground: () => foreground,
        reauthenticate: widget.session.reauthenticate);
    widget.session.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    controller.load();
  }

  void _changed() {
    if (!mounted || current) return;
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
    if (!foreground) controller.hide();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    reason.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    editingVersion = null;
    acknowledged = false;
    validation = null;
    reason.clear();
    await controller.load();
  }

  Future<void> _submit() async {
    if (!current || !foreground || !form.currentState!.validate()) return;
    if (!acknowledged) {
      setState(() => validation = '请确认采集范围和撤回影响。');
      return;
    }
    FocusScope.of(context).unfocus();
    await controller.submit(
        inventory: inventory, usage: usage, reason: reason.text);
  }

  Future<void> _acknowledge() async {
    // No modal holding private data can outlive scope revocation.
    if (!current || !foreground) return;
    await controller.acknowledge();
    if (current && controller.pending == null) await _reload();
  }

  Future<void> _reauthenticate() async {
    if (!current || !foreground || controller.busy || widget.session.busy) {
      return;
    }
    if (!await widget.session.reauthenticate() || !current || !foreground) {
      return;
    }
    // 身份恢复后只读核对；不能借重新验证自动重放原授权变更。
    if (controller.pending != null) {
      await controller.query();
    } else {
      await _reload();
    }
  }

  String allowed(bool value) => value ? '允许' : '关闭';
  Widget stateCard(String title, bool inventory, bool usage, int version) =>
      Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    Text(
                        '应用清单：${allowed(inventory)}\n系统使用摘要：${allowed(usage)}\n授权版本：$version'),
                  ])));
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final now = controller.settings,
            original = controller.committed,
            pending = controller.pending;
        if (now != null && pending == null && editingVersion != now.version) {
          editingVersion = now.version;
          inventory = now.inventoryEnabled;
          usage = now.usageEnabled;
        }
        final editable = current &&
            foreground &&
            controller.loaded &&
            pending == null &&
            now != null &&
            !controller.busy;
        return PopScope(
            canPop: !controller.busy,
            child: Scaffold(
                appBar: AppBar(title: const Text('观察授权')),
                body: !current || !foreground
                    ? const Center(child: Text('授权内容已隐藏，返回后请重新读取。'))
                    : ListView(padding: const EdgeInsets.all(20), children: [
                        Text(widget.target.displayName,
                            style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 12),
                        const Text(
                            '由监护人决定允许采集的范围。设备仍需系统许可；云端授权不会开启摄像头、读取网页内容或阻止其他应用。'),
                        const SizedBox(height: 16),
                        if (controller.busy) const LinearProgressIndicator(),
                        if (controller.error != null)
                          Semantics(
                              liveRegion: true,
                              child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  child: Text('${controller.error}'))),
                        if (controller.error is ParentApiException &&
                            (controller.error as ParentApiException).status ==
                                401)
                          TextButton.icon(
                              onPressed: controller.busy || widget.session.busy
                                  ? null
                                  : _reauthenticate,
                              icon: const Icon(Icons.verified_user_outlined),
                              label: const Text('重新安全验证并核对')),
                        if (now != null)
                          stateCard('本次核对的当前授权', now.inventoryEnabled,
                              now.usageEnabled, now.version),
                        if (pending == null) ...[
                          OutlinedButton.icon(
                              onPressed: controller.busy ? null : _reload,
                              icon: const Icon(Icons.refresh),
                              label: const Text('重新读取当前授权')),
                          if (now != null && controller.loaded)
                            Form(
                                key: form,
                                child: Column(children: [
                                  SwitchListTile(
                                      key:
                                          const Key('parent-observe-inventory'),
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text('应用清单'),
                                      subtitle: const Text(
                                          '当前设备用户可见的启动应用、版本和自报签名摘要；不保证完整安装清单。'),
                                      value: inventory,
                                      onChanged: editable
                                          ? (v) => setState(() => inventory = v)
                                          : null),
                                  SwitchListTile(
                                      key: const Key('parent-observe-usage'),
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text('系统使用摘要'),
                                      subtitle: const Text(
                                          '系统提供的应用使用区间和聚合时长。设备还需单独授予使用情况访问权限。'),
                                      value: usage,
                                      onChanged: editable
                                          ? (v) => setState(() => usage = v)
                                          : null),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                      key: const Key('parent-observe-reason'),
                                      controller: reason,
                                      enabled: editable,
                                      maxLength: 300,
                                      minLines: 1,
                                      maxLines: 3,
                                      decoration: const InputDecoration(
                                          labelText: '授权用途或撤回原因'),
                                      validator: (v) =>
                                          v != null && validConsentReason(v)
                                              ? null
                                              : '请填写 1–300 字符的原因，不含控制字符。'),
                                  const SizedBox(height: 12),
                                  Text(
                                      '应用清单：${allowed(now.inventoryEnabled)} → ${allowed(inventory)}\n'
                                      '系统使用摘要：${allowed(now.usageEnabled)} → ${allowed(usage)}'),
                                  const SizedBox(height: 12),
                                  const Text(
                                      '每次保存会清空当前应用清单，等待设备按新版本上报。关闭使用摘要会删除服务端摘要及回执头。'
                                      '离线设备要在下次联网核对时清理旧待发数据，不能据此确认远端已立即擦除。'),
                                  CheckboxListTile(
                                      key: const Key('parent-observe-confirm'),
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text('我已确认采集范围和撤回影响'),
                                      value: acknowledged,
                                      onChanged: editable
                                          ? (v) => setState(() {
                                                acknowledged = v == true;
                                                validation = null;
                                              })
                                          : null),
                                  if (validation != null)
                                    Semantics(
                                        liveRegion: true,
                                        child: Text(validation!)),
                                  const SizedBox(height: 12),
                                  FilledButton.icon(
                                      onPressed: editable ? _submit : null,
                                      icon: const Icon(
                                          Icons.verified_user_outlined),
                                      label: const Text('确认并进行安全验证')),
                                ])),
                        ] else ...[
                          const SizedBox(height: 12),
                          stateCard(
                              '待核对的原提交',
                              pending['body']['inventoryEnabled'],
                              pending['body']['usageEnabled'],
                              pending['body']['version']),
                          Text('原原因：${pending['body']['reason']}'),
                          SelectableText('操作编号：${pending['requestId']}'),
                          const Text('已冻结原范围、版本和原因。重新打开页面或查询结果都不会再次提交授权。'),
                          if (original != null)
                            stateCard('原操作已提交（历史结果）', original.inventoryEnabled,
                                original.usageEnabled, original.version),
                          OutlinedButton.icon(
                              onPressed:
                                  controller.busy ? null : controller.query,
                              icon: const Icon(Icons.manage_search),
                              label: const Text('只查询原操作结果')),
                          if (controller.queried) ...[
                            const Text(
                                '清除本机记录不会撤销任何授权。结果已删除或查不到时，不代表从未提交；请先核对当前授权和审计。系统不会换新编号重试。'),
                            TextButton(
                                onPressed:
                                    controller.busy ? null : _acknowledge,
                                child: const Text('我已核对，清除本机记录并重新读取')),
                          ],
                        ],
                        const SizedBox(height: 24),
                        const Text(
                            '本页管理应用清单与使用摘要授权。逐应用系统权限观察为另一项独立授权。启用该功能后，可在设备的“应用权限”页面配置。'),
                      ])));
      });
}
