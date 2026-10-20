import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:go_router/go_router.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/dialog_access.dart';
import '../ui/class_action_dialog.dart';
import '../ui/resource_page.dart';
import '../ui/owned_dialog_route.dart';
import 'device_subflow_scope.dart';

class ClassesPage extends StatefulWidget {
  final Session session;
  const ClassesPage({super.key, required this.session});
  @override
  State<ClassesPage> createState() => _ClassesPageState();
}

class _ClassesPageState extends State<ClassesPage> {
  Session get s => widget.session;
  late final DeviceSubflowScope pageScope;
  late final String root;
  bool archived = false, loading = false;
  bool _active = true, _rebuildPending = false;
  final ownerLost = ValueNotifier<bool>(false);
  Json? selected;
  Object? error;
  int revision = 0, generation = 0;

  bool get current => mounted && _active && !ownerLost.value &&
      s.tenant != null && pageScope.current;

  @override
  void initState() {
    super.initState();
    root = s.tenant == null ? '' : s.root;
    final session = s;
    pageScope = DeviceSubflowScope(session,
        permitted: () => mounted && _active && !ownerLost.value &&
            identical(widget.session, session) && session.canOpen('classes'));
    pageScope.addListener(accessChanged);
  }

  void accessChanged() {
    if (current) return;
    generation++;
    selected = null;
    error = null;
    loading = false;
    if (!mounted || !_active) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_rebuildPending) return;
      _rebuildPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _rebuildPending = false;
        if (mounted && _active) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  void deactivate() {
    _active = false;
    ownerLost.value = true;
    super.deactivate();
  }

  @override
  void dispose() {
    _active = false;
    ownerLost.value = true;
    generation++;
    pageScope.removeListener(accessChanged);
    pageScope.dispose();
    ownerLost.dispose();
    super.dispose();
  }

  void reauth() {
    if (current) s.login(stepUp: true);
  }

  DeviceSubflowScope capture({bool write = false}) {
    final selectedId = selected?['id'];
    final capturedGeneration = generation;
    return DeviceSubflowScope(s,
        permitted: () => current &&
            generation == capturedGeneration &&
            selected?['id'] == selectedId &&
            (!write || s.canManage));
  }

  Json response(dynamic value) {
    if (value is! Json || value.isEmpty) {
      throw const ApiFailure(502, 'INVALID_CLASS_RESPONSE');
    }
    return value;
  }

  Future<void> open(Json row) async {
    if (!current) return;
    final requested = ++generation;
    setState(() {
      selected = Map<String, dynamic>.of(row);
      loading = true;
      error = null;
    });
    final scope = capture();
    try {
      final result = response(
          await scope.api.send('GET', '$root/classes/${row['id']}',
              isCurrent: () => current && generation == requested));
      if (current && generation == requested) {
        setState(() {
          selected = result;
          revision++;
        });
      }
    } catch (failure) {
      if (current && generation == requested) {
        setState(() => error = failure);
      }
    } finally {
      scope.dispose();
      if (current && generation == requested) {
        setState(() => loading = false);
      }
    }
  }

  Future<bool> form(
      {required DeviceSubflowScope scope,
      required String title,
      required String description,
      required String field,
      required String fieldLabel,
      required String submit,
      required Future<Json> Function(Api, Json) send,
      BuildContext? parent,
      String? name,
      Map<String, String>? options}) async {
    final parentContext = parent ?? context;
    if (!parentContext.mounted) return false;
    final parentRoute = ModalRoute.of(parentContext);
    var live = true, parentOpen = true;
    bool permitted() => live && parentOpen && current && scope.current &&
        parentContext.mounted &&
        (parentRoute == null || parentRoute.isActive) &&
        (parentRoute is! OwnedDialogRoute<dynamic> || parentRoute.available);
    if (!permitted()) return false;
    final access = DialogAccessBinding(parentContext,
        accessChanges: Listenable.merge([scope, ownerLost]),
        hasAccess: permitted);
    late final OwnedDialogRoute<Json> route;
    late final Api api;
    route = OwnedDialogRoute<Json>(
        context: parentContext,
        barrierDismissible: false,
        builder: (_) => ClassActionDialog(
            title: title,
            description: description,
            field: field,
            fieldLabel: fieldLabel,
            submitLabel: submit,
            initialName: name,
            options: options,
            accessChanges: access.changes,
            hasAccess: () => access.permitted() && route.available && route.isActive,
            onSubmit: (body) => send(api, body),
            reauth: () {
              if (permitted() && route.available && route.isCurrent) reauth();
            }));
    api = scope.api.scoped(() =>
        access.permitted() && route.available && route.isActive);
    parentRoute?.popped.then<void>((_) {
      parentOpen = false;
      if (!live) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (live && route.available) route.finish();
      });
    });
    try {
      final result = await presentOwnedDialog<Json>(parentContext, route);
      return permitted() && result != null;
    } finally {
      live = false;
      access.dispose();
    }
  }

  Future<void> create() async {
    if (!current || !s.canManage) return;
    final scope = capture(write: true), key = requestId();
    try {
      await form(
          scope: scope,
          title: '新建班级',
          description: '创建后可添加已有学生档案，并在成员管理中分配任课教师。',
          field: 'name',
          fieldLabel: '班级名称',
          submit: '创建班级',
          send: (api, body) async => response(await api.send(
              'POST', '$root/classes', body: body, key: key)));
    } finally {
      scope.dispose();
    }
  }

  Future<void> rename() async {
    if (!current || !s.canManage || selected == null) return;
    final scope = capture(write: true),
        selectedClass = Map<String, dynamic>.of(selected!),
        key = requestId();
    try {
      await form(
          scope: scope,
          title: '修改班级名称',
          description: '班级标识和已有名册保持关联。',
          field: 'name',
          fieldLabel: '班级名称',
          submit: '保存名称',
          name: selectedClass['name'],
          send: (api, body) async => response(await api.send(
              'PATCH', '$root/classes/${selectedClass['id']}',
              body: body, version: selectedClass['version'], key: key)));
      if (current && scope.current) await open(selectedClass);
    } finally {
      scope.dispose();
    }
  }

  Future<void> addStudent() async {
    if (!current || !s.canManage || selected == null) return;
    final scope = capture(write: true),
        selectedClass = Map<String, dynamic>.of(selected!),
        key = requestId();
    try {
      final lists = await Future.wait([
        scope.api.all('$root/subjects'),
        scope.api.all('$root/classes/${selectedClass['id']}/students')
      ]);
      if (!current || !scope.current) return;
      final existing = lists[1].map((r) => r['id']).toSet();
      final choices = {
        for (final row in lists[0])
          if (!existing.contains(row['id']) && row['archived'] != true &&
              row['archivedAt'] == null)
            row['id'] as String: row['nickname'] as String
      };
      await form(
          scope: scope,
          title: '添加学生',
          description: '关联本机构的已有档案。一个班级最多 500 人；家庭档案不会被导入。',
          field: 'subjectId',
          fieldLabel: '学生档案',
          submit: '加入班级',
          options: choices,
          send: (api, body) async => response(await api.send(
              'POST', '$root/classes/${selectedClass['id']}/students',
              body: body, version: selectedClass['version'], key: key)));
      if (current && scope.current) await open(selectedClass);
    } finally {
      scope.dispose();
    }
  }

  Future<bool> transfer(Json student, {required BuildContext parent}) async {
    if (!parent.mounted) return false;
    final parentRoute = ModalRoute.of(parent);
    bool parentActive() => parent.mounted && parentRoute?.isActive == true &&
        (parentRoute is! OwnedDialogRoute<dynamic> || parentRoute.available);
    if (!current || !s.canManage || selected == null || !parentActive()) {
      return false;
    }
    final scope = capture(write: true),
        selectedClass = Map<String, dynamic>.of(selected!),
        key = requestId();
    try {
      final api = scope.api.scoped(parentActive);
      final classes = await api.all('$root/classes');
      if (!current || !scope.current || !parentActive()) return false;
      final targets = {
        for (final item in classes)
          if (item['id'] != selectedClass['id'] && item['state'] == 'ACTIVE')
            item['id'] as String: item
      };
      return await form(
          scope: scope,
          parent: parent,
          title: '转移学生到其他班级',
          description:
              '将 ${student['nickname']} 从 ${selectedClass['name']} 移至目标班级。双方名册将同时更新，教师访问范围随之变化。',
          field: 'targetClassId',
          fieldLabel: '目标班级',
          submit: '确认转班',
          options: {
            for (final item in targets.entries)
              item.key: item.value['name'] as String
          },
          send: (api, body) async => response(await api.send('POST',
              '$root/classes/${selectedClass['id']}/students/${student['id']}/transfer',
              body: {
                ...body,
                'targetVersion': targets[body['targetClassId']]!['version']
              },
              version: selectedClass['version'], key: key)));
    } finally {
      scope.dispose();
    }
  }

  Future<void> student(Json row) async {
    if (!current || selected == null) return;
    final scope = capture(),
        selectedClass = Map<String, dynamic>.of(selected!),
        key = requestId();
    try {
      await scopedDetailsDialog(context, '学生名册详情', {
        '学生': row['nickname'],
        '档案标识': row['id'],
        '状态': row['archived'] == true ? '档案已归档' : '在班',
        '加入时间': dateLabel(row['addedAt'])
      }, reauth: reauth, accessChanges: Listenable.merge([scope, ownerLost]),
          hasAccess: () => current && scope.current, actions: [
        if (s.canManage && selectedClass['state'] == 'ACTIVE') ...[
          if (row['archived'] != true)
            DetailAction('转班', (dialog) async {
              if (!dialog.mounted || !scope.current) return;
              final complete = captureDialogCompletion(dialog);
              if (scope.current && await transfer(row, parent: dialog)) complete();
            }, closeOnSuccess: false),
          DetailAction('移出班级', (dialog) async {
            if (!dialog.mounted || !scope.current) return;
            final complete = captureDialogCompletion(dialog);
            final route = ModalRoute.of(dialog);
            bool actionCurrent() => dialog.mounted && route?.isActive == true &&
                current && scope.current && s.canManage &&
                (route is! OwnedDialogRoute<dynamic> || route.available);
            if (!actionCurrent()) return;
            final confirmationAccess = DialogAccessBinding(dialog,
                accessChanges: Listenable.merge([scope, ownerLost]),
                hasAccess: actionCurrent);
            Json? confirmed;
            try {
              confirmed = await formDialog(dialog,
                  title: '移出班级',
                  description:
                      '将 ${row['nickname']} 移出 ${selectedClass['name']}。学生档案和设备保留；仅依靠本班取得的教师访问权限将失效。',
                  fields: const [], initial: const {}, submit: '确认移出',
                  accessChanges: confirmationAccess.changes,
                  hasAccess: confirmationAccess.permitted,
                  onSubmit: (_) async => <String, dynamic>{'confirmed': true});
            } finally {
              confirmationAccess.dispose();
            }
            if (!actionCurrent() || confirmed?['confirmed'] != true) return;
            await scope.api.send('DELETE',
                '$root/classes/${selectedClass['id']}/students/${row['id']}',
                version: selectedClass['version'], key: key,
                isCurrent: actionCurrent);
            if (current && scope.current) complete();
          }, destructive: true, closeOnSuccess: false),
        ]
      ]);
      if (current && scope.current) await open(selectedClass);
    } finally {
      scope.dispose();
    }
  }

  Future<void> archive() async {
    if (!current || !s.canManage || selected == null) return;
    final scope = capture(write: true),
        selectedClass = Map<String, dynamic>.of(selected!),
        key = requestId();
    try {
      await scopedDetailsDialog(context, '归档班级', {
        '班级': selectedClass['name'],
        '名册人数': selectedClass['studentCount'],
        '影响': '归档后停止名册调整和本班教师访问，保留学生档案及历史名册。',
        '恢复': '当前不支持重新启用，请确认班级已结束使用。'
      }, reauth: reauth, accessChanges: Listenable.merge([scope, ownerLost]),
          hasAccess: () => current && scope.current, actions: [
        DetailAction('确认归档', (dialog) async {
          if (!dialog.mounted || !scope.current) return;
          final route = ModalRoute.of(dialog);
          bool actionCurrent() => dialog.mounted && route?.isActive == true &&
              current && scope.current && s.canManage &&
              (route is! OwnedDialogRoute<dynamic> || route.available);
          if (!actionCurrent()) return;
          await scope.api.send('POST',
              '$root/classes/${selectedClass['id']}/archive',
              version: selectedClass['version'], key: key,
              isCurrent: actionCurrent);
        }, destructive: true)
      ]);
      if (current && scope.current) await open(selectedClass);
    } finally {
      scope.dispose();
    }
  }

  Future<void> act(Future<void> Function() action) async {
    if (!current) return;
    final scope = capture();
    try {
      await action();
    } catch (failure) {
      if (current && scope.current) setState(() => error = failure);
    } finally {
      scope.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (s.tenant?['kind'] != 'ORGANIZATION') {
      return const Notice('班级与名册仅适用于机构工作空间。');
    }
    if (!current) {
      return const Notice('工作空间或权限已变化，请重新打开班级与名册。', warning: true);
    }
    if (selected == null) {
      return ResourcePage(
        key: ValueKey('$root-$archived'),
        api: pageScope.api,
        path: '$root/classes${archived ? '?includeArchived=true' : ''}',
        title: '班级与名册',
        subtitle: s.role == 'TEACHER'
            ? '查看获授班级及学生名册。访问范围由机构管理员维护。'
            : '维护学生名册，按班级分配教师的查看范围。',
        emptyTitle: '暂无可查看班级',
        emptyDescription:
            s.canManage ? '新建班级后，添加学生并为教师分配班级范围。' : '管理员分配班级后，名册会显示在这里。',
        reauth: reauth,
        create: s.canManage ? create : null,
        createLabel: '新建班级',
        toolbar: [
          if (s.canManage)
            FilterChip(
                label: const Text('包含已归档'),
                selected: archived,
                onSelected: (v) {
                  if (current) setState(() => archived = v);
                })
        ],
        columns: [
          ColumnSpec(
              '班级',
              (r) => Text(r['name'],
                  style: const TextStyle(fontWeight: FontWeight.w600))),
          ColumnSpec('学生人数', (r) => Text('${r['studentCount']} 人')),
          ColumnSpec('状态', (r) => StatusTag(r['state'])),
          ColumnSpec('最近更新', (r) => Text(dateLabel(r['updatedAt'])))
        ],
        onOpen: open,
      );
    }
    final c = selected!, editable = s.canManage && c['state'] == 'ACTIVE';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextButton.icon(
          onPressed: () {
            if (!current) return;
            setState(() {
              generation++;
              selected = null;
              error = null;
              loading = false;
            });
          },
          icon: const Icon(Icons.arrow_back, size: 18),
          label: const Text('返回班级列表')),
      const SizedBox(height: 12),
      if (loading) const LinearProgressIndicator(),
      if (error != null)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: FailureView(error!, retry: () => open(c), reauth: reauth)),
      if (!loading && error == null)
        ResourcePage(
          key: ValueKey('${c['id']}-$revision'),
          api: pageScope.api,
          path: '$root/classes/${c['id']}/students',
          title: c['name'],
          subtitle: s.role == 'TEACHER'
              ? '名册含 ${c['studentCount']} 个关联 · 仅显示未归档学生'
              : '${c['state'] == 'ARCHIVED' ? '已归档 · ' : ''}${c['studentCount']} 位学生 · 权限随当前名册生效',
          reauth: reauth,
          create: editable ? addStudent : null,
          createLabel: '添加学生',
          emptyTitle: '名册为空',
          emptyDescription:
              editable ? '添加本机构的已有学生档案。没有档案时，可先前往“儿童档案”创建。' : '该班级尚无学生记录。',
          notice: c['state'] == 'ARCHIVED' ? '历史名册仅供管理查阅。已停止通过本班授予教师访问。' : null,
          toolbar: [
            if (editable) ...[
              OutlinedButton(
                  onPressed: () => act(rename), child: const Text('修改名称')),
              OutlinedButton(
                  onPressed: () {
                    if (current && s.canManage) context.go('/members');
                  },
                  child: const Text('分配教师')),
              TextButton(
                  onPressed: () => act(archive), child: const Text('归档班级'))
            ]
          ],
          columns: [
            ColumnSpec('学生', (r) => Text(r['nickname'])),
            ColumnSpec(
                '档案状态', (r) => Text(r['archived'] == true ? '已归档' : '有效')),
            ColumnSpec('加入时间', (r) => Text(dateLabel(r['addedAt'])))
          ],
          onOpen: student,
        ),
    ]);
  }
}
