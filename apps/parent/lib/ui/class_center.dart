import 'operation_result_terminal_panel.dart';
import 'package:flutter/material.dart';
import '../core/organization_classes.dart';
import '../core/paged_collection.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';

mixin _ClassScope<T extends StatefulWidget> on State<T>
    implements WidgetsBindingObserver {
  ParentSession get session;
  late final String tenant, actor, role;
  late final int generation;
  bool foreground = true;
  Route<dynamic>? dialog;
  bool get current =>
      mounted &&
      !_operationOwnerLost &&
      session.authenticated &&
      session.tenant?['id'] == tenant &&
      session.tenant?['kind'] == 'ORGANIZATION' &&
      session.profile?['subject'] == actor &&
      session.role == role &&
      session.generation == generation &&
      const {'OWNER', 'ORG_ADMIN'}.contains(role);
  bool get available => current && foreground;
  String get root => '/tenants/$tenant';
  bool _operationOwnerLost = false;
  @override
  void deactivate() {
    _operationOwnerLost = true;
    super.deactivate();
  }

  @override
  void initState() {
    super.initState();
    tenant = session.tenant!['id'];
    actor = session.profile!['subject'];
    role = session.role;
    generation = session.generation;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    session.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }

  void _changed() {
    if (!mounted || current) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      if (dialog?.isActive == true) dialog!.navigator?.removeRoute(dialog!);
      final route = ModalRoute.of(context);
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground && dialog?.isActive == true) {
      dialog!.navigator?.removeRoute(dialog!);
    }
    if (mounted) setState(() {});
  }

  Future<bool> confirm(String title, String text, String action) async {
    if (!available) return false;
    final route = DialogRoute<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(title),
                content: SingleChildScrollView(child: Text(text)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('返回')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(action))
                ]));
    dialog = route;
    try {
      return await Navigator.of(context).push(route) == true && available;
    } finally {
      if (identical(dialog, route)) dialog = null;
    }
  }

  @override
  void dispose() {
    session.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class ClassCenter extends StatefulWidget {
  final ParentSession session;
  final ClassOperationStore? store;
  const ClassCenter({super.key, required this.session, this.store});
  @override
  State<ClassCenter> createState() => _ClassCenterState();
}

class _ClassCenterState extends State<ClassCenter>
    with WidgetsBindingObserver, _ClassScope {
  @override
  ParentSession get session => widget.session;
  late PagedCollection classes;
  late final ClassOperationController operation;
  final search = TextEditingController();
  bool archived = false, opening = false;
  @override
  void initState() {
    super.initState();
    _collection();
    operation = ClassOperationController(
        api: session.api,
        tenant: tenant,
        actor: actor,
        store: widget.store ?? ClassOperationStore(),
        isCurrent: () => available);
    operation.load();
  }

  void _collection() {
    classes = PagedCollection(
        session.api, '$root/classes?includeArchived=$archived',
        isCurrent: () => available, validateItem: readSchoolClass);
  }

  Future<void> _open([Json? row]) async {
    if (!available || opening || operation.busy) return;
    setState(() => opening = true);
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => row == null
              ? _ClassAction(
                  session: session, operation: operation, action: 'CREATE')
              : _ClassDetail(
                  session: session, operation: operation, id: row['id'])));
    } finally {
      if (mounted) setState(() => opening = false);
    }
    if (available) await classes.reload();
  }

  @override
  void dispose() {
    classes.dispose();
    operation.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('班级与名册')),
      body: !available
          ? const Center(child: Text('班级内容已隐藏。'))
          : AnimatedBuilder(
              animation: Listenable.merge([classes, operation]),
              builder: (context, _) {
                final rows = classes.items
                    .where((c) =>
                        (c['name'] as String).contains(search.text.trim()))
                    .toList();
                return RefreshIndicator(
                    onRefresh: classes.reload,
                    child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(20),
                        children: [
                          Text('按班管理，清楚掌握学生归属',
                              style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 8),
                          const Text('从已有学生档案建立名册。学生可加入多个班级，教师访问范围随有效班级授权变化。'),
                          _ClassRecovery(
                              session: session,
                              operation: operation,
                              confirm: confirm,
                              onCleared: classes.reload),
                          FilledButton.icon(
                              onPressed: opening || !operation.canSubmit
                                  ? null
                                  : () => _open(),
                              icon: const Icon(Icons.add),
                              label: const Text('新建班级')),
                          const SizedBox(height: 16),
                          TextField(
                              controller: search,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                  labelText: '查找已加载的班级',
                                  prefixIcon: Icon(Icons.search))),
                          SwitchListTile(
                              title: const Text('包含已归档班级'),
                              value: archived,
                              onChanged: opening
                                  ? null
                                  : (v) {
                                      classes.dispose();
                                      setState(() {
                                        archived = v;
                                        _collection();
                                      });
                                    }),
                          if (classes.loading) const LinearProgressIndicator(),
                          if (classes.error != null)
                            _ClassError(
                                error: classes.error!, retry: classes.reload),
                          if (classes.loaded && rows.isEmpty)
                            Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(search.text.trim().isEmpty
                                    ? '还没有班级。新建班级后即可添加学生。'
                                    : '已加载的班级中没有匹配项。')),
                          for (final c in rows)
                            Card(
                                child: ListTile(
                                    leading: Icon(c['state'] == 'ACTIVE'
                                        ? Icons.groups_outlined
                                        : Icons.archive_outlined),
                                    title: Text(c['name']),
                                    subtitle: Text(
                                        '${c['studentCount']} 个档案关联 · ${c['state'] == 'ACTIVE' ? '使用中' : '已归档'}'),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: opening ? null : () => _open(c))),
                          if (classes.hasMore)
                            OutlinedButton(
                                onPressed: classes.loadingMore
                                    ? null
                                    : classes.loadMore,
                                child: Text(
                                    classes.loadingMore ? '正在加载…' : '加载更多')),
                        ]));
              }));
}

class _ClassRecovery extends StatelessWidget {
  final ParentSession session;
  final ClassOperationController operation;
  final Future<bool> Function(String, String, String) confirm;
  final Future<void> Function() onCleared;
  const _ClassRecovery(
      {required this.session,
      required this.operation,
      required this.confirm,
      required this.onCleared});
  @override
  Widget build(BuildContext context) => operation.resultTerminal != null
      ? ParentResultTerminalPanel(operation: operation, onViewCurrent: onCleared, onEnded: onCleared)
      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ParentKnownOperationReceipt(operation: operation),
        if (operation.busy) const LinearProgressIndicator(),
        if (operation.error != null)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(classFailure(operation.error!),
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
        if (!operation.loaded && !operation.busy)
          OutlinedButton(
              onPressed: operation.load, child: const Text('重新读取恢复记录')),
        if (operation.pending != null)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                            operation.committed == null ? '核对上一次班级操作' : '操作已保存',
                            style: Theme.of(context).textTheme.titleLarge),
                        Text(classOperationLabels[operation.pending!['input']
                            ['operation']]!),
                        if (operation.committed != null) ...[
                          for (final c in operation.committed!)
                            Text(
                                '原结果：${c['name']} · 版本 ${c['version']} · ${c['studentCount']} 个关联'),
                          const Text('原结果为历史快照，当前名册可能已有后续变化。'),
                        ],
                        if (operation.latest != null)
                          for (final c in operation.latest!)
                            Text(
                                '最近核对：${c['name']} · 版本 ${c['version']} · ${c['studentCount']} 个关联'),
                        if (operation.queried && operation.committed == null)
                          const Text('未找到可读取结果，不代表没有提交。请核对班级和名册后再处理提醒。'),
                        ExpansionTile(title: const Text('操作详情'), children: [
                          SelectableText(
                              '请求编号：${operation.pending!['requestId']}')
                        ]),
                        Wrap(spacing: 8, children: [
                          OutlinedButton(
                              onPressed: operation.busy
                                  ? null
                                  : () => operation.recover(),
                              child: const Text('核对原操作')),
                          if (operation.committed == null && !operation.operationKnownSuccessful)
                            OutlinedButton(
                                onPressed: operation.busy
                                    ? null
                                    : () async {
                                        if (await confirm(
                                            '重试原操作？',
                                            '保留原内容、请求编号及班级版本。不会自动覆盖较新的名册。',
                                            '重试原操作')) {
                                          await operation.recover(retry: true);
                                        }
                                      },
                                child: const Text('重试原操作')),
                          if (operation.queried)
                            FilledButton(
                                onPressed: operation.busy
                                    ? null
                                    : () async {
                                        final owner = ModalRoute.of(context);
                                        bool active() => context.mounted && operation.operationCurrent &&
                                            owner?.isActive == true && owner?.isCurrent == true;
                                        if (!active()) return;
                                        if (operation.committed == null &&
                                            !await parentOperationConfirmation(context,
                                                operation: operation, accessChanges: session,
                                                isCurrent: () => operation.operationCurrent,
                                                title: '已核对班级和名册？',
                                                description: '清除本机提醒不会撤销服务端操作。请确认已经检查班级和相关名册。',
                                                confirmLabel: '清除提醒')) return;
                                        if (!active()) return;
                                        if (await operation.acknowledge() && active()) {
                                          await onCleared();
                                        }
                                      },
                                child: Text(operation.committed == null
                                    ? '已核对，清除提醒'
                                    : '完成核对')),
                        ]),
                        if (operation.error is ParentApiException &&
                            (operation.error as ParentApiException).code ==
                                'REAUTH_REQUIRED') ...[
                          const Text('验证后重新打开班级页面，即可核对或重试原操作。'),
                          OutlinedButton(
                              onPressed: operation.busy
                                  ? null
                                  : session.reauthenticate,
                              child: const Text('重新安全验证')),
                        ],
                      ]))),
      ]);
}

class _ClassDetail extends StatefulWidget {
  final ParentSession session;
  final ClassOperationController operation;
  final String id;
  const _ClassDetail(
      {required this.session, required this.operation, required this.id});
  @override
  State<_ClassDetail> createState() => _ClassDetailState();
}

class _ClassDetailState extends State<_ClassDetail>
    with WidgetsBindingObserver, _ClassScope {
  @override
  ParentSession get session => widget.session;
  Json? classroom;
  late final PagedCollection students;
  Object? error;
  bool reading = false, opening = false;
  @override
  void initState() {
    super.initState();
    students = PagedCollection(
        session.api, '$root/classes/${widget.id}/students',
        isCurrent: () => available, validateItem: validateClassStudent);
    _reload();
  }

  Future<void> _reload() async {
    if (!available || reading) return;
    setState(() {
      reading = true;
      classroom = null;
      error = null;
    });
    try {
      final row = readSchoolClass(await session.api
          .object('$root/classes/${widget.id}', isCurrent: () => available));
      if (row['id'] != widget.id) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (available) setState(() => classroom = row);
    } catch (failure) {
      if (available) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => reading = false);
    }
    if (available) await students.reload();
  }

  Future<void> _act(String action, [Json? student]) async {
    if (!available ||
        opening ||
        classroom == null ||
        !widget.operation.canSubmit) return;
    setState(() => opening = true);
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => _ClassAction(
              session: session,
              operation: widget.operation,
              action: action,
              before: classroom,
              student: student)));
    } finally {
      if (mounted) setState(() => opening = false);
    }
    if (available) await _reload();
  }

  @override
  void dispose() {
    students.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('班级名册'), actions: [
        IconButton(
            tooltip: '刷新班级和名册',
            onPressed: !available || reading ? null : _reload,
            icon: const Icon(Icons.refresh))
      ]),
      body: !available
          ? const Center(child: Text('班级内容已隐藏。'))
          : AnimatedBuilder(
              animation: Listenable.merge([students, widget.operation]),
              builder: (context, _) {
                final editable = classroom?['state'] == 'ACTIVE' &&
                    widget.operation.canSubmit &&
                    !opening &&
                    !reading;
                return RefreshIndicator(
                    onRefresh: _reload,
                    child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(20),
                        children: [
                          _ClassRecovery(
                              session: session,
                              operation: widget.operation,
                              confirm: confirm,
                              onCleared: _reload),
                          if (reading) const LinearProgressIndicator(),
                          if (error != null)
                            _ClassError(error: error!, retry: _reload),
                          if (classroom != null) ...[
                            Text(classroom!['name'],
                                style:
                                    Theme.of(context).textTheme.headlineSmall),
                            Text(
                                '${classroom!['studentCount']} 个关联（含已归档档案） · 版本 ${classroom!['version']}'),
                            if (classroom!['state'] == 'ARCHIVED')
                              const Text('班级已归档。名册保留供核对，不再授予教师访问范围。'),
                            const SizedBox(height: 16),
                            if (classroom!['state'] == 'ACTIVE')
                              Wrap(spacing: 8, children: [
                                FilledButton.icon(
                                    onPressed:
                                        editable ? () => _act('ADD') : null,
                                    icon: const Icon(Icons.person_add_alt_1),
                                    label: const Text('添加学生')),
                                OutlinedButton(
                                    onPressed:
                                        editable ? () => _act('RENAME') : null,
                                    child: const Text('修改名称')),
                                TextButton(
                                    onPressed:
                                        editable ? () => _act('ARCHIVE') : null,
                                    child: const Text('归档班级')),
                              ]),
                            const SizedBox(height: 16),
                            Text('学生名册',
                                style: Theme.of(context).textTheme.titleLarge),
                            const Text('移出或转班会影响仅依靠本班获得的教师权限；学生档案和设备不会删除。'),
                            if (students.loading)
                              const LinearProgressIndicator(),
                            if (students.error != null)
                              _ClassError(
                                  error: students.error!,
                                  retry: students.reload),
                            if (students.loaded && students.items.isEmpty)
                              const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Text('名册为空，可添加已有学生档案。')),
                            for (final s in students.items)
                              Card(
                                  child: ListTile(
                                      leading: const Icon(Icons.person_outline),
                                      title: Text(s['nickname']),
                                      subtitle: Text(s['archived']
                                          ? '档案已归档 · 可移出名册'
                                          : '在本班名册中'),
                                      trailing: !editable
                                          ? null
                                          : PopupMenuButton<String>(
                                              tooltip:
                                                  '管理 ${s['nickname']} 的班级关联',
                                              onSelected: (action) =>
                                                  _act(action, s),
                                              itemBuilder: (_) => [
                                                    if (!s['archived'])
                                                      const PopupMenuItem(
                                                          value: 'TRANSFER',
                                                          child:
                                                              Text('转到其他班级')),
                                                    const PopupMenuItem(
                                                        value: 'REMOVE',
                                                        child: Text('移出本班'))
                                                  ]))),
                            if (students.hasMore)
                              OutlinedButton(
                                  onPressed: students.loadingMore
                                      ? null
                                      : students.loadMore,
                                  child: const Text('加载更多学生')),
                          ],
                        ]));
              }));
}

class _ClassAction extends StatefulWidget {
  final ParentSession session;
  final ClassOperationController operation;
  final String action;
  final Json? before, student;
  const _ClassAction(
      {required this.session,
      required this.operation,
      required this.action,
      this.before,
      this.student});
  @override
  State<_ClassAction> createState() => _ClassActionState();
}

class _ClassActionState extends State<_ClassAction>
    with WidgetsBindingObserver, _ClassScope {
  @override
  ParentSession get session => widget.session;
  final name = TextEditingController();
  final form = GlobalKey<FormState>();
  Json? selected;
  bool picking = false;
  Object? error;
  @override
  void initState() {
    super.initState();
    if (widget.action == 'RENAME') name.text = widget.before!['name'];
  }

  Future<void> _pick() async {
    if (!available || picking) return;
    setState(() => picking = true);
    try {
      final result = await Navigator.of(context).push<Json>(MaterialPageRoute(
          builder: (_) => _ClassPicker(
              session: session,
              subject: widget.action == 'ADD',
              excludedClass: widget.before?['id'])));
      if (available && result != null) setState(() => selected = result);
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  String get explanation => switch (widget.action) {
        'CREATE' => '只需填写班级名称。创建后添加已有学生，并在成员管理中分配任课教师。',
        'RENAME' => '修改名称保留学生关联。',
        'ADD' => '从已有的有效学生档案中选择。一个学生可以加入多个班级，每班最多 500 个档案关联。',
        'REMOVE' => '只移出本班，不删除学生档案或设备。仅依靠本班的教师访问权限会失效。',
        'TRANSFER' => '同时从原班移出、加入目标班。其他班级关联保留；教师访问范围随名册变化。',
        _ => '归档会停止本班授予的教师访问范围，保留历史名册。当前没有取消归档入口，请谨慎确认。',
      };
  Future<void> _save() async {
    if (!available ||
        picking ||
        !widget.operation.canSubmit ||
        !form.currentState!.validate()) return;
    final op = widget.action, before = widget.before;
    if ((op == 'ADD' || op == 'TRANSFER') && selected == null) {
      setState(() => error = const FormatException('请先选择学生或目标班级。'));
      return;
    }
    final Json input = {
      'operation': op,
      if (op == 'CREATE' || op == 'RENAME') 'name': name.text.trim(),
      if (before != null) ...{
        'classId': before['id'],
        'version': before['version']
      },
      if (op == 'ADD') 'subjectId': selected!['id'],
      if (op == 'REMOVE' || op == 'TRANSFER')
        'subjectId': widget.student!['id'],
      if (op == 'TRANSFER') ...{
        'targetClassId': selected!['id'],
        'targetVersion': selected!['version']
      },
    };
    final title = classOperationLabels[op]!;
    if (!await confirm(
        '确认$title？',
        [
          if (before != null) '班级：${before['name']}',
          if (op == 'CREATE' || op == 'RENAME') '名称：${name.text.trim()}',
          if (op == 'ADD') '学生：${selected!['nickname']}',
          if (widget.student != null) '学生：${widget.student!['nickname']}',
          if (op == 'TRANSFER') '转入：${selected!['name']}',
          explanation,
        ].join('\n'),
        '确认$title')) return;
    await widget.operation.submit(input,
        before: before, target: op == 'TRANSFER' ? selected : null);
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(classOperationLabels[widget.action]!)),
      body: !available
          ? const Center(child: Text('操作内容已隐藏。'))
          : AnimatedBuilder(
              animation: widget.operation,
              builder: (context, _) =>
                  ListView(padding: const EdgeInsets.all(20), children: [
                    _ClassRecovery(
                        session: session,
                        operation: widget.operation,
                        confirm: confirm,
                        onCleared: () async {
                          final owner = ModalRoute.of(context);
                          if (available && owner?.isActive == true && owner?.isCurrent == true) {
                            owner!.navigator?.pop();
                          }
                        }),
                    if (widget.operation.pending == null)
                      Form(
                          key: form,
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(explanation),
                                const SizedBox(height: 20),
                                if (widget.before != null)
                                  ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      leading:
                                          const Icon(Icons.groups_outlined),
                                      title: Text(widget.before!['name']),
                                      subtitle: Text(
                                          '当前读取版本 ${widget.before!['version']}')),
                                if (widget.student != null)
                                  ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      leading: const Icon(Icons.person_outline),
                                      title: Text(widget.student!['nickname'])),
                                if (widget.action == 'CREATE' ||
                                    widget.action == 'RENAME')
                                  TextFormField(
                                      controller: name,
                                      enabled: !widget.operation.busy,
                                      maxLength: 100,
                                      decoration: const InputDecoration(
                                          labelText: '班级名称'),
                                      validator: (v) =>
                                          v == null || v.trim().isEmpty
                                              ? '请输入班级名称'
                                              : null),
                                if (widget.action == 'ADD' ||
                                    widget.action == 'TRANSFER')
                                  OutlinedButton.icon(
                                      onPressed:
                                          picking || widget.operation.busy
                                              ? null
                                              : _pick,
                                      icon: const Icon(Icons.search),
                                      label: Text(
                                          selected == null
                                              ? (widget.action == 'ADD'
                                                  ? '选择已有学生'
                                                  : '选择目标班级')
                                              : selected![widget.action == 'ADD'
                                                  ? 'nickname'
                                                  : 'name'])),
                                if (error != null)
                                  Text(classFailure(error!),
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error)),
                                const SizedBox(height: 24),
                                FilledButton(
                                    onPressed:
                                        picking || !widget.operation.canSubmit
                                            ? null
                                            : _save,
                                    child: Text(
                                        '核对并${classOperationLabels[widget.action]}')),
                              ])),
                  ])));
}

class _ClassPicker extends StatefulWidget {
  final ParentSession session;
  final bool subject;
  final String? excludedClass;
  const _ClassPicker(
      {required this.session, required this.subject, this.excludedClass});
  @override
  State<_ClassPicker> createState() => _ClassPickerState();
}

class _ClassPickerState extends State<_ClassPicker>
    with WidgetsBindingObserver, _ClassScope {
  @override
  ParentSession get session => widget.session;
  late final PagedCollection items;
  final search = TextEditingController();
  @override
  void initState() {
    super.initState();
    items = PagedCollection(
        session.api, '$root/${widget.subject ? 'subjects' : 'classes'}',
        isCurrent: () => available,
        validateItem: (row) {
          if (widget.subject) {
            if (row['id'] is! String ||
                !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
                    .hasMatch(row['id']) ||
                row['nickname'] is! String ||
                row['nickname'].trim().isEmpty ||
                row['nickname'].length > 100) {
              throw const ParentApiException(502, 'INVALID_RESPONSE');
            }
          } else {
            readSchoolClass(row);
          }
        });
  }

  @override
  void dispose() {
    items.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(widget.subject ? '选择学生' : '选择目标班级')),
      body: !available
          ? const Center(child: Text('目录已隐藏。'))
          : AnimatedBuilder(
              animation: items,
              builder: (context, _) {
                final rows = items.items
                    .where((r) =>
                        r['id'] != widget.excludedClass &&
                        (widget.subject || r['state'] == 'ACTIVE') &&
                        (r[widget.subject ? 'nickname' : 'name'] as String)
                            .contains(search.text.trim()))
                    .toList();
                return ListView.builder(
                    padding: const EdgeInsets.all(20),
                    itemCount: rows.length + 2,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Column(children: [
                          TextField(
                              controller: search,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                  labelText: '搜索已加载的记录',
                                  prefixIcon: Icon(Icons.search))),
                          if (items.loading) const LinearProgressIndicator(),
                          if (items.error != null)
                            _ClassError(
                                error: items.error!, retry: items.reload),
                          if (items.loaded && rows.isEmpty)
                            const Padding(
                                padding: EdgeInsets.all(24),
                                child: Text('没有可选记录，请先创建档案或其他班级。'))
                        ]);
                      }
                      if (index == rows.length + 1) {
                        return items.hasMore
                            ? OutlinedButton(
                                onPressed:
                                    items.loadingMore ? null : items.loadMore,
                                child: const Text('加载更多'))
                            : const SizedBox.shrink();
                      }
                      final row = rows[index - 1];
                      return ListTile(
                          title:
                              Text(row[widget.subject ? 'nickname' : 'name']),
                          subtitle: widget.subject
                              ? null
                              : Text('${row['studentCount']} 个关联'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            if (available) Navigator.pop(context, row);
                          });
                    });
              }));
}

class _ClassError extends StatelessWidget {
  final Object error;
  final Future<void> Function() retry;
  const _ClassError({required this.error, required this.retry});
  @override
  Widget build(BuildContext context) => Column(children: [
        Text(classFailure(error)),
        TextButton(onPressed: retry, child: const Text('重新读取'))
      ]);
}
