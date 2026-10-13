import 'package:flutter/material.dart';
import '../core/device_groups.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';

/// Captures adult institution scope once and closes this exact route on revocation.
mixin GroupScope<T extends StatefulWidget> on State<T> {
  ParentSession get session;
  late final String tenant, actor, role;
  bool get current =>
      mounted &&
      session.authenticated &&
      session.tenant?['id'] == tenant &&
      session.profile?['subject'] == actor &&
      session.role == role &&
      session.tenant?['kind'] == 'ORGANIZATION' &&
      const {'OWNER', 'ORG_ADMIN'}.contains(role);
  @override
  void initState() {
    super.initState();
    tenant = session.tenant!['id'];
    actor = session.profile!['subject'];
    role = session.role;
    session.addListener(_scopeChanged);
  }

  void _scopeChanged() {
    if (!mounted || current) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
    // A role-only change need not rebuild the parent shell. Schedule the frame
    // explicitly so access revocation cannot leave an idle detail screen visible.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    session.removeListener(_scopeChanged);
    super.dispose();
  }
}

class GroupOperationPage extends StatefulWidget {
  final ParentSession session;
  final Json input;
  final String? groupName;
  final GroupOperationStore? store;
  final Map<String, String> targetNames;
  const GroupOperationPage(
      {super.key,
      required this.session,
      required this.input,
      this.groupName,
      this.store,
      this.targetNames = const {}});
  @override
  State<GroupOperationPage> createState() => _GroupOperationPageState();
}

class _GroupOperationPageState extends State<GroupOperationPage>
    with GroupScope {
  @override
  ParentSession get session => widget.session;
  late final GroupOperationController controller;
  late final name = TextEditingController(text: widget.input['name'] ?? '');
  final form = GlobalKey<FormState>();
  bool leaving = false;
  @override
  void initState() {
    super.initState();
    controller = GroupOperationController(
        api: session.api,
        store: widget.store ?? GroupOperationStore(),
        tenant: tenant,
        actor: actor,
        isCurrent: () => current,
        reauthenticate: session.reauthenticate);
    controller.load();
  }

  @override
  void dispose() {
    controller.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!current || controller.busy || !form.currentState!.validate()) return;
    final body = {...widget.input};
    if (const {'CREATE', 'RENAME'}.contains(body['operation'])) {
      body['name'] = name.text.trim();
    }
    await controller.execute(body);
  }

  Future<void> _acknowledge() async {
    final result = controller.result;
    if (result == null) {
      final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: const Text('已核对设备组目录？'),
                  content:
                      const Text('查不到结果不证明没有提交。请先核对目录和审计；清除后不会撤销任何操作，也不会自动重试。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('继续保留')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('已核对，清除本机记录'))
                  ]));
      if (ok != true || !current) return;
    }
    if (await controller.acknowledge() && current) {
      setState(() => leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (current) Navigator.pop(context, result?['current']);
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final pending = controller.pending;
        final input = pending?['body'] as Json? ?? widget.input;
        final op = input['operation'];
        final committed = controller.result?['committed'];
        final now = controller.result?['current'];
        return PopScope(
            canPop: !controller.busy || leaving,
            child: Scaffold(
                appBar: AppBar(
                    title: Text(
                        pending == null ? groupOperations[op]! : '核对设备组操作')),
                body: ListView(padding: const EdgeInsets.all(20), children: [
                  Text(groupOperations[op]!,
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  if (widget.groupName != null && pending == null)
                    Text('设备组：${widget.groupName}'),
                  if (input['groupId'] != null)
                    SelectableText(
                        '组编号：${input['groupId']}\n原修订：${input['version']}'),
                  const SizedBox(height: 12),
                  Text(op == 'ARCHIVE'
                      ? '归档后不能再维护成员或用于新的按组选择，历史仍保留。已发布配置和设备注册不会撤销。'
                      : op == 'REMOVE'
                          ? '仅移出目录关联，不注销设备、不撤销已发布配置。失效成员也可清理。'
                          : '设备组用于整理机构设备。加入成员不会自动发布或执行系统策略。'),
                  if (input['devices'] is List) ...[
                    const SizedBox(height: 12),
                    Text('本次明确选择 ${(input['devices'] as List).length} 台'),
                    ExpansionTile(title: const Text('核对设备及注册周期'), children: [
                      for (final d in input['devices'])
                        ListTile(
                            title: Text(pending == null
                                ? widget.targetNames[d['deviceId']] ??
                                    d['deviceId']
                                : d['deviceId']),
                            subtitle: Text(
                                '设备：${d['deviceId']}\n注册周期：${d['registrationId']}')),
                    ]),
                  ],
                  if (controller.busy) const LinearProgressIndicator(),
                  if (controller.error != null)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text('${controller.error}')),
                  if (!controller.loaded && !controller.busy)
                    OutlinedButton(
                        onPressed: controller.load,
                        child: const Text('重新读取待核对记录')),
                  if (controller.loaded && pending == null)
                    Form(
                        key: form,
                        child: Column(children: [
                          if (const {'CREATE', 'RENAME'}.contains(op))
                            TextFormField(
                                controller: name,
                                enabled: !controller.busy,
                                maxLength: 100,
                                decoration: const InputDecoration(
                                    labelText: '设备组名称',
                                    helperText: '例如：三年级一班平板'),
                                validator: (v) => v == null ||
                                        v.trim().isEmpty ||
                                        v.length > 100
                                    ? '请填写 1–100 字符的名称'
                                    : null),
                          const SizedBox(height: 20),
                          FilledButton.icon(
                              onPressed: controller.busy ? null : _submit,
                              icon: const Icon(Icons.verified_user_outlined),
                              label: const Text('确认并进行安全验证')),
                        ])),
                  if (pending != null) ...[
                    const SizedBox(height: 16),
                    if (input['name'] != null) Text('原请求名称：${input['name']}'),
                    SelectableText('请求编号：${pending['requestId']}'),
                    const Text('原请求已保存在本机。结果未知时只查询，不自动重发。'),
                    if (committed != null)
                      Card(
                          child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        '已确认当次提交 · 修订 ${committed['version']}'),
                                    Text(
                                        '当前名称：${now['name']}\n当前修订：${now['version']} · 成员记录 ${now['deviceCount']}'),
                                    if (now['version'] != committed['version'])
                                      const Text('提交后设备组已有后续变更，请以当前详情为准。'),
                                    const Text('目录操作完成不代表设备策略已执行。'),
                                  ]))),
                    OutlinedButton(
                        onPressed: controller.busy ? null : controller.query,
                        child: const Text('查询原操作结果')),
                    if (controller.queried && committed == null)
                      const Text('暂未查到可核对结果，请返回目录与审计核对后再决定是否清除。'),
                    if (controller.queried)
                      FilledButton(
                          onPressed: controller.busy ? null : _acknowledge,
                          child: Text(
                              committed != null ? '完成核对，打开当前详情' : '核对后清除本机记录')),
                  ],
                ])));
      });
}
