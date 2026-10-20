import 'operation_result_terminal_panel.dart';
import 'package:flutter/material.dart';

import '../core/parent_api.dart';
import '../core/parent_session.dart';
import '../core/policy_creation.dart';

/// Entry for both fresh creation and cross-process recovery of the last request.
class PolicyCreationPage extends StatefulWidget {
  final ParentSession session;
  final Json? template;
  final PolicyCreationStore? store;
  const PolicyCreationPage(
      {super.key, required this.session, this.template, this.store});
  @override
  State<PolicyCreationPage> createState() => _PolicyCreationPageState();
}

class _PolicyCreationPageState extends State<PolicyCreationPage> {
  late final String tenant, actor, role;
  late final PolicyCreationController controller;
  final name = TextEditingController();
  final form = GlobalKey<FormState>();
  String kind = 'POLICY';
  bool dirty = false, allowExit = false;
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
    _operationIdentity = ParentOperationIdentity(widget.session, onRevoked: _scopeChanged);
    tenant = widget.session.tenant!['id'];
    actor = widget.session.profile!['subject'];
    role = widget.session.role;
    controller = PolicyCreationController(
        api: _operationIdentity.scopedApi(widget.session.api),
        store: widget.store ?? PolicyCreationStore(),
        tenant: tenant,
        actor: actor,
        isCurrent: () => current && _operationIdentity.dispatchable && !widget.session.busy);
    widget.session.addListener(_scopeChanged);
    controller.load();
  }

  void _scopeChanged() {
    if (!mounted || current) return;
    _operationOwnerLost = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    _operationIdentity.dispose();
    widget.session.removeListener(_scopeChanged);
    controller.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    if (controller.busy) return;
    if (dirty && controller.pending == null) {
      final discard = await showDialog<bool>(
          context: context,
          builder: (ctx) =>
              AlertDialog(title: const Text('放弃尚未提交的名称？'), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('继续填写')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('放弃'))
              ]));
      if (!current || discard != true) return;
    }
    if (!mounted) return;
    setState(() => allowExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _create() async {
    if (!current || !form.currentState!.validate()) return;
    await controller.create(
        name: name.text,
        kind: kind,
        templateId: widget.template?['id'],
        templateRevision: widget.template?['revision']);
  }

  Future<void> _open() async {
    final owner = ModalRoute.of(context);
    bool active() => current && owner?.isActive == true && owner?.isCurrent == true;
    final draft = controller.result;
    if (draft == null || !active() || controller.busy) return;
    if (await controller.acknowledge() && active()) {
      setState(() => allowExit = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (active()) owner!.navigator?.pop(draft);
      });
    }
  }

  Future<void> _clear() async {
    final owner = ModalRoute.of(context);
    bool active() => current && owner?.isActive == true && owner?.isCurrent == true;
    if (!active() || controller.busy) return;
    final confirmed = await parentOperationConfirmation(context,
        operation: controller, accessChanges: widget.session, isCurrent: () => current,
        title: '已在策略中心核对原创建结果？',
        description: '查询不到不代表从未创建。请先核对列表和管理台审计记录，避免重复创建。这只清除本机提醒，不删除服务器草稿。',
        cancelLabel: '返回核对', confirmLabel: '已核对，清除提醒');
    if (confirmed && active() && await controller.acknowledge() && active()) {
      setState(() {
        dirty = false;
        name.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => controller.resultTerminal != null
          ? parentResultTerminalPage(context, title: '策略创建核对', operation: controller)
          : PopScope(
          canPop: allowExit ||
              (!controller.busy && (!dirty || controller.pending != null)),
          onPopInvoked: (didPop) {
            if (!didPop) _leave();
          },
          child: Scaffold(
            appBar: AppBar(
                title: Text(widget.template == null ? '新建策略与恢复' : '从模板创建策略'),
                leading: IconButton(
                    tooltip: '返回',
                    onPressed: controller.busy ? null : _leave,
                    icon: const Icon(Icons.arrow_back))),
            body: ListView(padding: const EdgeInsets.all(20), children: [
              const Text('创建后继续编辑与预览',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text('创建草稿不会改变设备设置。未确认的创建会保留本机恢复提醒，系统不会自动重发。'),
              const SizedBox(height: 20),
              ParentKnownOperationReceipt(operation: controller),
              if (controller.busy) const LinearProgressIndicator(),
              if (controller.error != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text('${controller.error}',
                        style: const TextStyle(color: Color(0xFF9A3931)))),
              if (!controller.loaded && !controller.busy)
                OutlinedButton(
                    onPressed: controller.load, child: const Text('重新读取恢复记录')),
              if (controller.pending != null) ...[
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  controller.result == null
                                      ? '请先核对原创建'
                                      : '原创建已确认',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 8),
                              Text('提交名称：${controller.pending!.name}'),
                              Text(controller.pending!.templateId == null
                                  ? '来源：新建空草稿'
                                  : '来源：模板副本'),
                              SelectableText(
                                  '请求编号：${controller.pending!.requestId}'),
                              if (controller.result != null) ...[
                                Text('当前名称：${controller.result!['name']}'),
                                Text('当前修订：${controller.result!['revision']}'),
                                const Text('草稿可能已被管理员继续编辑；打开后读取最新内容。'),
                              ] else if (controller.queried)
                                const Text(
                                    '未找到可读取的原创建结果。记录可能已被清理，请先核对策略列表和管理台审计记录。'),
                            ]))),
                OutlinedButton(
                    onPressed: controller.busy ? null : controller.query,
                    child: const Text('查询原创建结果')),
                if (controller.result != null)
                  FilledButton(
                      onPressed: controller.busy ? null : _open,
                      child: const Text('打开草稿'))
                else if (controller.queried)
                  TextButton(
                      onPressed: controller.busy ? null : _clear,
                      child: const Text('已核对，清除本机提醒')),
              ] else if (controller.loaded) ...[
                if (controller.sourceStale)
                  const Card(
                      child: Padding(
                          padding: EdgeInsets.all(18),
                          child: Text('原模板已发生变化，请返回详情刷新，再重新复制。')))
                else
                  Form(
                      key: form,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (widget.template != null)
                              Card(
                                  child: Padding(
                                      padding: const EdgeInsets.all(18),
                                      child: Text(
                                          '来源：${widget.template!['name']} · 修订 ${widget.template!['revision']}\n副本保存独立规则，模板后续修改不会自动同步。'))),
                            if (widget.template == null)
                              DropdownButtonFormField<String>(
                                  value: kind,
                                  decoration:
                                      const InputDecoration(labelText: '草稿类型'),
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'POLICY', child: Text('策略草稿')),
                                    DropdownMenuItem(
                                        value: 'TEMPLATE', child: Text('可复用模板'))
                                  ],
                                  onChanged: controller.busy
                                      ? null
                                      : (v) {
                                          if (v != null) {
                                            setState(() {
                                              kind = v;
                                              dirty = true;
                                            });
                                          }
                                        }),
                            const SizedBox(height: 16),
                            TextFormField(
                                controller: name,
                                enabled: !controller.busy,
                                maxLength: 100,
                                decoration: const InputDecoration(
                                    labelText: '名称',
                                    hintText: '例如：工作日学习安排',
                                    border: OutlineInputBorder()),
                                validator: (v) => v == null || v.trim().isEmpty
                                    ? '请填写便于识别的名称'
                                    : v.trim().length > 100
                                        ? '名称过长，请缩短后再提交'
                                        : null,
                                onChanged: (_) => setState(() => dirty = true)),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                                onPressed: controller.busy ? null : _create,
                                icon: const Icon(Icons.add),
                                label: Text(widget.template == null
                                    ? '创建空草稿'
                                    : '创建独立副本')),
                          ])),
              ],
            ]),
          )));
}
