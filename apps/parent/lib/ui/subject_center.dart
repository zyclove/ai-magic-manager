import 'operation_result_terminal_panel.dart';
import 'package:flutter/material.dart';
import '../core/paged_collection.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import '../core/subjects.dart';
import 'class_center.dart';
import 'member_center.dart';

/// Identity is captured once; background content is hidden and reads invalidated.
mixin SubjectScope<T extends StatefulWidget> on State<T>
    implements WidgetsBindingObserver {
  ParentSession get session;
  late final String tenant, actor, role;
  bool foreground = true;
  bool get current =>
      mounted &&
      !_operationOwnerLost &&
      _operationIdentity.current &&
      session.canDecide &&
      session.tenant?['id'] == tenant &&
      session.profile?['subject'] == actor &&
      session.role == role;
  bool get available => current && foreground;
  void hidePrivate();
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
    _operationIdentity = ParentOperationIdentity(session, onRevoked: _scopeChanged);
    tenant = session.tenant!['id'];
    actor = session.profile!['subject'];
    role = session.role;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    session.addListener(_scopeChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  void _scopeChanged() {
    if (!mounted || current) return;
    _operationOwnerLost = true;
    hidePrivate();
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
    if (!foreground) hidePrivate();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _operationIdentity.dispose();
    session.removeListener(_scopeChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class SubjectCenter extends StatefulWidget {
  final ParentSession session;
  final SubjectChangeStore? store;
  const SubjectCenter({super.key, required this.session, this.store});
  @override
  State<SubjectCenter> createState() => _SubjectCenterState();
}

class _SubjectCenterState extends State<SubjectCenter>
    with WidgetsBindingObserver, SubjectScope {
  @override
  ParentSession get session => widget.session;
  PagedCollection? items;
  final search = TextEditingController();
  bool archived = false, opening = false;
  @override
  void initState() {
    super.initState();
    if (available) _collection();
  }

  void _collection() {
    items = PagedCollection(_operationIdentity.scopedApi(session.api),
        '/tenants/$tenant/subjects/management?includeArchived=$archived',
        isCurrent: () => available);
  }

  @override
  void hidePrivate() {
    items?.dispose();
    items = null;
    search.clear();
    if (mounted) setState(() {});
  }

  Future<void> _reload() async {
    if (!available || opening) return;
    if (items == null) {
      setState(_collection);
    } else {
      await items!.reload();
    }
  }

  Future<void> _open(Json input) async {
    if (!available || opening) return;
    setState(() => opening = true);
    try {
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => SubjectEditor(
              session: session, input: input, store: widget.store)));
    } finally {
      if (mounted) setState(() => opening = false);
    }
    if (available) await _reload();
  }

  @override
  void dispose() {
    items?.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('儿童与学生档案'), actions: [
        TextButton.icon(
            onPressed: available && !opening
                ? () => _open(const {'operation': 'CREATE'})
                : null,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('添加 / 恢复'))
      ]),
      body: !available
          ? const Center(child: Text('档案内容已隐藏。'))
          : items == null
              ? Center(
                  child: OutlinedButton(
                      onPressed: _reload, child: const Text('重新读取档案')))
              : AnimatedBuilder(
                  animation: items!,
                  builder: (context, _) {
                    final list = items!,
                        query = search.text.trim().toLowerCase();
                    final rows = list.items
                        .where((r) => '${r['nickname']} ${r['id']}'
                            .toLowerCase()
                            .contains(query))
                        .toList();
                    return RefreshIndicator(
                        onRefresh: _reload,
                        child: ListView.builder(
                            padding: const EdgeInsets.all(20),
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount: rows.length + 2,
                            itemBuilder: (context, index) {
                              if (index == 0) {
                                return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text('先认识孩子，再连接设备',
                                          style: Theme.of(context)
                                              .textTheme
                                              .headlineSmall),
                                      const SizedBox(height: 8),
                                      const Text('只需昵称和年龄段，无需真实姓名、生日或照片。'),
                                      const SizedBox(height: 16),
                                      if (const {'OWNER', 'ORG_ADMIN'}
                                          .contains(role))
                                        Card(
                                            child: ListTile(
                                                leading: const Icon(Icons
                                                    .admin_panel_settings_outlined),
                                                title: const Text('成员与权限'),
                                                subtitle: const Text(
                                                    '分配职责、学生和班级访问范围'),
                                                trailing: const Icon(
                                                    Icons.chevron_right),
                                                onTap: opening
                                                    ? null
                                                    : () async {
                                                        setState(() =>
                                                            opening = true);
                                                        try {
                                                          await Navigator.of(
                                                                  context)
                                                              .push(MaterialPageRoute<
                                                                      void>(
                                                                  builder: (_) =>
                                                                      MemberCenter(
                                                                          session:
                                                                              session)));
                                                        } finally {
                                                          if (mounted) {
                                                            setState(() =>
                                                                opening =
                                                                    false);
                                                          }
                                                        }
                                                        if (available) {
                                                          await _reload();
                                                        }
                                                      })),
                                      if (session.tenant?['kind'] ==
                                              'ORGANIZATION' &&
                                          const {'OWNER', 'ORG_ADMIN'}
                                              .contains(role))
                                        Card(
                                            child: ListTile(
                                                leading: const Icon(
                                                    Icons.groups_outlined),
                                                title: const Text('班级与名册'),
                                                subtitle:
                                                    const Text('按班管理学生、转班和归档'),
                                                trailing: const Icon(
                                                    Icons.chevron_right),
                                                onTap: opening
                                                    ? null
                                                    : () async {
                                                        setState(() =>
                                                            opening = true);
                                                        try {
                                                          await Navigator.of(
                                                                  context)
                                                              .push(MaterialPageRoute<
                                                                      void>(
                                                                  builder: (_) =>
                                                                      ClassCenter(
                                                                          session:
                                                                              session)));
                                                        } finally {
                                                          if (mounted) {
                                                            setState(() =>
                                                                opening =
                                                                    false);
                                                          }
                                                        }
                                                        if (available) {
                                                          await _reload();
                                                        }
                                                      })),
                                      TextField(
                                          controller: search,
                                          onChanged: (_) => setState(() {}),
                                          decoration: const InputDecoration(
                                              labelText: '查找已加载的档案',
                                              prefixIcon: Icon(Icons.search))),
                                      SwitchListTile(
                                          contentPadding: EdgeInsets.zero,
                                          title: const Text('同时显示已归档档案'),
                                          value: archived,
                                          onChanged: opening
                                              ? null
                                              : (v) {
                                                  items?.dispose();
                                                  setState(() {
                                                    archived = v;
                                                    _collection();
                                                  });
                                                }),
                                      if (list.loading)
                                        const LinearProgressIndicator(),
                                      if (list.error != null) ...[
                                        Text('${list.error}'),
                                        TextButton(
                                            onPressed: _reload,
                                            child: const Text('重新读取'))
                                      ],
                                      if (list.loaded && rows.isEmpty)
                                        const Padding(
                                            padding: EdgeInsets.symmetric(
                                                vertical: 24),
                                            child:
                                                Text('暂无匹配档案。可以添加，也可以清空搜索。')),
                                    ]);
                              }
                              if (index == rows.length + 1) {
                                return Column(children: [
                                  if (list.loadingMore)
                                    const LinearProgressIndicator(),
                                  if (list.hasMore)
                                    TextButton(
                                        onPressed: list.loadingMore
                                            ? null
                                            : list.loadMore,
                                        child: const Text('加载更多档案')),
                                ]);
                              }
                              final row = rows[index - 1];
                              Json? value;
                              try {
                                value = readSubject(row);
                              } catch (_) {
                                /* Malformed records are never editable. */
                              }
                              final snapshot = value;
                              return Card(
                                  child: ListTile(
                                      leading: Icon(
                                          snapshot?['state'] == 'ARCHIVED'
                                              ? Icons.inventory_2_outlined
                                              : Icons.face_outlined),
                                      title: Text(
                                          snapshot?['nickname'] ?? '档案资料待核对'),
                                      subtitle: Text(snapshot == null
                                          ? '请刷新后重试'
                                          : '${subjectAges[snapshot['ageBand']]} · ${snapshot['state'] == 'ACTIVE' ? '当前使用' : '已归档'}'),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: opening || snapshot == null
                                          ? null
                                          : () => _open({
                                                'operation': 'UPDATE',
                                                ...snapshot
                                              })));
                            }));
                  }));
}

class SubjectEditor extends StatefulWidget {
  final ParentSession session;
  final Json input;
  final SubjectChangeStore? store;
  const SubjectEditor(
      {super.key, required this.session, required this.input, this.store});
  @override
  State<SubjectEditor> createState() => _SubjectEditorState();
}

class _SubjectEditorState extends State<SubjectEditor>
    with WidgetsBindingObserver, SubjectScope {
  @override
  ParentSession get session => widget.session;
  late final SubjectChangeController controller;
  late final name = TextEditingController(text: widget.input['nickname'] ?? '');
  String? age;
  bool archiving = false,
      accepted = false,
      leaving = false,
      discard = false,
      acknowledgeMissing = false;
  final form = GlobalKey<FormState>();
  bool get dirty =>
      name.text != (widget.input['nickname'] ?? '') ||
      age != widget.input['ageBand'];
  @override
  void initState() {
    super.initState();
    age = widget.input['ageBand'];
    controller = SubjectChangeController(
        api: _operationIdentity.scopedApi(session.api),
        store: widget.store ?? SubjectChangeStore(),
        tenant: tenant,
        actor: actor,
        isCurrent: () => current && _operationIdentity.dispatchable,
        foreground: () => foreground,
        reauthenticate: _operationIdentity.reauthenticate);
    controller.load();
  }

  @override
  void hidePrivate() {
    controller.hide();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!available || controller.busy || !form.currentState!.validate()) return;
    if (archiving && !accepted) {
      setState(() => discard = false);
      return;
    }
    final op = archiving ? 'ARCHIVE' : widget.input['operation'];
    await controller.execute({
      'operation': op,
      if (op != 'CREATE') 'subjectId': widget.input['id'],
      if (op != 'CREATE') 'version': widget.input['version'],
      if (!archiving) 'nickname': name.text.trim(),
      if (!archiving) 'ageBand': age
    });
  }

  Future<void> _done() async {
    final owner = ModalRoute.of(context);
    bool active() => current && owner?.isActive == true && owner?.isCurrent == true;
    if (!active() || controller.busy ||
        (controller.result == null && !acknowledgeMissing)) return;
    if (await controller.acknowledge() && active()) {
      setState(() => leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (active()) owner!.navigator?.pop();
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (controller.resultTerminal != null) {
          return parentResultTerminalPage(context, title: '档案操作核对', operation: controller);
        }
        final pending = controller.pending,
            result = controller.result,
            editable = controller.loaded && !controller.busy;
        final archived = widget.input['state'] == 'ARCHIVED';
        return PopScope(
            canPop: leaving || !controller.busy && (!dirty || pending != null),
            onPopInvoked: (didPop) {
              if (!didPop && !controller.busy && available) {
                setState(() => discard = true);
              }
            },
            child: Scaffold(
                appBar: AppBar(
                    title: Text(pending != null
                        ? '核对档案操作'
                        : widget.input['operation'] == 'CREATE'
                            ? '添加档案'
                            : '管理档案')),
                body: !available
                    ? const Center(child: Text('档案内容已隐藏。'))
                    : ListView(padding: const EdgeInsets.all(20), children: [
                        if (discard)
                          Card(
                              child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(children: [
                                    const Text('还有未保存的内容。'),
                                    Wrap(spacing: 8, children: [
                                      TextButton(
                                          onPressed: () =>
                                              setState(() => discard = false),
                                          child: const Text('继续编辑')),
                                      TextButton(
                                          onPressed: () {
                                            setState(() => leaving = true);
                                            WidgetsBinding.instance
                                                .addPostFrameCallback((_) {
                                              if (current) {
                                                Navigator.pop(context);
                                              }
                                            });
                                          },
                                          child: const Text('放弃并返回')),
                                    ])
                                  ]))),
                        ParentKnownOperationReceipt(operation: controller),
              if (controller.busy) const LinearProgressIndicator(),
                        if (controller.error != null)
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Semantics(
                                  liveRegion: true,
                                  child: Text('${controller.error}'))),
                        if (pending != null) ...[
                          const Icon(Icons.fact_check_outlined, size: 40),
                          const SizedBox(height: 12),
                          Text(subjectOperations[pending['body']['operation']]!,
                              style: Theme.of(context).textTheme.headlineSmall),
                          const Text('本机保留了原操作编号。查询只核对结果，不会重新提交。'),
                          ExpansionTile(title: const Text('原操作信息'), children: [
                            SelectableText(
                                '编号：${pending['requestId']}\n档案：${pending['body']['subjectId'] ?? '新建时生成'}')
                          ]),
                          if (result != null) ...[
                            _SubjectResult(
                                title: '原操作已提交（历史结果）',
                                value: result['committed']),
                            _SubjectResult(
                                title: '当前档案', value: result['current']),
                          ],
                          OutlinedButton.icon(
                              onPressed:
                                  controller.busy ? null : controller.query,
                              icon: const Icon(Icons.refresh),
                              label: const Text('核对原操作与当前状态')),
                          if (controller.queried && result == null)
                            CheckboxListTile(
                                value: acknowledgeMissing,
                                onChanged: controller.busy
                                    ? null
                                    : (v) => setState(
                                        () => acknowledgeMissing = v == true),
                                title: const Text('我已另行核对目录或审计'),
                                subtitle: const Text(
                                    '查不到结果不证明没有提交。清除本机记录不会撤销操作，也不会自动重试。')),
                          if (controller.queried)
                            FilledButton(
                                onPressed: controller.busy ||
                                        result == null && !acknowledgeMissing
                                    ? null
                                    : _done,
                                child: Text(
                                    result == null ? '清除本机记录并返回' : '完成，返回档案')),
                        ] else if (!controller.loaded) ...[
                          const Text('请读取档案操作状态后继续。'),
                          OutlinedButton(
                              onPressed:
                                  controller.busy ? null : controller.load,
                              child: const Text('读取 / 恢复')),
                        ] else if (archived) ...[
                          _SubjectResult(title: '已归档档案', value: widget.input),
                          const Text('当前不支持重新启用。归档与个人数据删除、设备退出是不同操作。'),
                        ] else
                          Form(
                              key: form,
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(archiving ? '归档前请确认' : '昵称与年龄段',
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineSmall),
                                    const SizedBox(height: 12),
                                    if (archiving) ...[
                                      Text('即将归档：${widget.input['nickname']}'),
                                      const Text(
                                          '归档后停止该档案的常规访问与新增管理，相关授权按服务端规则失效。历史数据按保留规则处理；不会证明设备本地已经退出或擦除。当前不支持重新启用。'),
                                      CheckboxListTile(
                                          contentPadding: EdgeInsets.zero,
                                          value: accepted,
                                          onChanged: editable
                                              ? (v) => setState(
                                                  () => accepted = v == true)
                                              : null,
                                          title: const Text('已了解影响，确认归档')),
                                    ] else ...[
                                      const Text('建议使用孩子熟悉的昵称，不需要填写真实姓名。'),
                                      const SizedBox(height: 16),
                                      TextFormField(
                                          key: const Key('subject-nickname'),
                                          controller: name,
                                          maxLength: 60,
                                          enabled: editable,
                                          onChanged: (_) => setState(() {}),
                                          decoration: const InputDecoration(
                                              labelText: '昵称'),
                                          validator: (v) =>
                                              subjectNameValid(v?.trim())
                                                  ? null
                                                  : '请输入有效昵称（1–60 字）'),
                                      DropdownButtonFormField<String>(
                                          value: age,
                                          isExpanded: true,
                                          isDense: false,
                                          decoration: const InputDecoration(
                                              labelText: '年龄段'),
                                          items: [
                                            for (final e in subjectAges.entries)
                                              DropdownMenuItem(
                                                  value: e.key,
                                                  child: Text(e.value))
                                          ],
                                          onChanged: editable
                                              ? (v) => setState(() => age = v)
                                              : null,
                                          validator: (v) =>
                                              v == null ? '请选择年龄段' : null),
                                    ],
                                    const SizedBox(height: 24),
                                    FilledButton.icon(
                                        key: const Key('subject-submit'),
                                        onPressed:
                                            editable && (!archiving || accepted)
                                                ? _submit
                                                : null,
                                        icon: Icon(archiving
                                            ? Icons.archive_outlined
                                            : Icons.check),
                                        label: Text(
                                            archiving ? '安全验证并归档' : '安全验证并保存')),
                                    if (widget.input['operation'] != 'CREATE')
                                      TextButton(
                                          onPressed: editable
                                              ? () => setState(() {
                                                    archiving = !archiving;
                                                    accepted = false;
                                                  })
                                              : null,
                                          child: Text(
                                              archiving ? '返回编辑' : '归档这个档案')),
                                  ])),
                      ])));
      });
}

class _SubjectResult extends StatelessWidget {
  final String title;
  final Json value;
  const _SubjectResult({required this.title, required this.value});
  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(value['nickname']),
            Text(
                '${subjectAges[value['ageBand']]} · ${value['state'] == 'ARCHIVED' ? '已归档' : '当前使用'} · 修订 ${value['version']}'),
            ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('档案编号'),
                children: [SelectableText(value['id'])]),
          ])));
}
