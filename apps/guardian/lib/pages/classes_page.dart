import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/class_action_dialog.dart';
import '../ui/resource_page.dart';

class ClassesPage extends StatefulWidget {
  final Session session;
  const ClassesPage({super.key, required this.session});
  @override
  State<ClassesPage> createState() => _ClassesPageState();
}

class _ClassesPageState extends State<ClassesPage> {
  Session get s => widget.session;
  bool archived = false, loading = false;
  Json? selected;
  Object? error;
  int revision = 0;
  void reauth() => s.login(stepUp: true);
  void sameWorkspace(String root) {
    if (s.root != root) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<void> open(Json row) async {
    final root = s.root;
    setState(() {
      selected = row;
      loading = true;
      error = null;
    });
    try {
      final result =
          await s.api.send('GET', '$root/classes/${row['id']}') as Json;
      if (mounted && s.root == root) {
        setState(() {
          selected = result;
          revision++;
        });
      }
    } catch (e) {
      if (mounted && s.root == root) setState(() => error = e);
    } finally {
      if (mounted && s.root == root) setState(() => loading = false);
    }
  }

  Future<bool> form(
      {required String title,
      required String description,
      required String field,
      required String fieldLabel,
      required String submit,
      required Future<Json> Function(Json) send,
      String? name,
      Map<String, String>? options}) async {
    final result = await showDialog<Json>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ClassActionDialog(
            title: title,
            description: description,
            field: field,
            fieldLabel: fieldLabel,
            submitLabel: submit,
            initialName: name,
            options: options,
            onSubmit: send,
            reauth: reauth));
    return result != null;
  }

  Future<void> create() async {
    final root = s.root, key = requestId();
    await form(
        title: '新建班级',
        description: '创建后可添加已有学生档案，并在成员管理中分配任课教师。',
        field: 'name',
        fieldLabel: '班级名称',
        submit: '创建班级',
        send: (body) async {
          sameWorkspace(root);
          return await s.api.send('POST', '$root/classes', body: body, key: key)
              as Json;
        });
  }

  Future<void> rename() async {
    final root = s.root,
        current = Map<String, dynamic>.of(selected!),
        key = requestId();
    await form(
        title: '修改班级名称',
        description: '班级标识和已有名册保持关联。',
        field: 'name',
        fieldLabel: '班级名称',
        submit: '保存名称',
        name: current['name'],
        send: (body) async {
          sameWorkspace(root);
          return await s.api.send('PATCH', '$root/classes/${current['id']}',
              body: body, version: current['version'], key: key) as Json;
        });
    if (mounted && s.root == root) await open(current);
  }

  Future<void> addStudent() async {
    final root = s.root,
        current = Map<String, dynamic>.of(selected!),
        key = requestId();
    final lists = await Future.wait([
      s.api.all('$root/subjects'),
      s.api.all('$root/classes/${current['id']}/students')
    ]);
    if (!mounted || s.root != root) return;
    final existing = lists[1].map((r) => r['id']).toSet();
    final choices = {
      for (final r in lists[0])
        if (!existing.contains(r['id']))
          r['id'] as String: r['nickname'] as String
    };
    await form(
        title: '添加学生',
        description: '关联本机构的已有档案。一个班级最多 500 人；家庭档案不会被导入。',
        field: 'subjectId',
        fieldLabel: '学生档案',
        submit: '加入班级',
        options: choices,
        send: (body) async {
          sameWorkspace(root);
          return await s.api.send(
              'POST', '$root/classes/${current['id']}/students',
              body: body, version: current['version'], key: key) as Json;
        });
    if (mounted && s.root == root) await open(current);
  }

  Future<bool> transfer(Json student) async {
    final root = s.root,
        current = Map<String, dynamic>.of(selected!),
        key = requestId();
    final classes = await s.api.all('$root/classes');
    if (!mounted || s.root != root) return false;
    final targets = {
      for (final c in classes)
        if (c['id'] != current['id']) c['id'] as String: c
    };
    return form(
        title: '转移学生到其他班级',
        description:
            '将 ${student['nickname']} 从 ${current['name']} 移至目标班级。双方名册将同时更新，教师访问范围随之变化。',
        field: 'targetClassId',
        fieldLabel: '目标班级',
        submit: '确认转班',
        options: {
          for (final e in targets.entries) e.key: e.value['name'] as String
        },
        send: (body) async {
          sameWorkspace(root);
          return await s.api.send('POST',
              '$root/classes/${current['id']}/students/${student['id']}/transfer',
              body: {
                ...body,
                'targetVersion': targets[body['targetClassId']]!['version']
              },
              version: current['version'],
              key: key) as Json;
        });
  }

  Future<void> student(Json row) async {
    final root = s.root,
        current = Map<String, dynamic>.of(selected!),
        key = requestId();
    await actionDetails(
        context,
        '学生名册详情',
        {
          '学生': row['nickname'],
          '档案标识': row['id'],
          '状态': row['archived'] == true ? '档案已归档' : '在班',
          '加入时间': dateLabel(row['addedAt'])
        },
        reauth: reauth,
        actions: [
          if (s.canManage && current['state'] == 'ACTIVE') ...[
            if (row['archived'] != true)
              DetailAction('转班', (dialog) async {
                if (await transfer(row) && dialog.mounted) {
                  Navigator.pop(dialog);
                }
              }, closeOnSuccess: false),
            DetailAction('移出班级', (dialog) async {
              if (!await confirmAction(dialog, '移出班级',
                  '将 ${row['nickname']} 移出 ${current['name']}。学生档案和设备保留；仅依靠本班取得的教师访问权限将失效。')) {
                return;
              }
              sameWorkspace(root);
              await s.api.send('DELETE',
                  '$root/classes/${current['id']}/students/${row['id']}',
                  version: current['version'], key: key);
              if (dialog.mounted) Navigator.pop(dialog);
            }, destructive: true, closeOnSuccess: false),
          ]
        ]);
    if (mounted && s.root == root) await open(current);
  }

  Future<void> archive() async {
    final root = s.root,
        current = Map<String, dynamic>.of(selected!),
        key = requestId();
    await actionDetails(
        context,
        '归档班级',
        {
          '班级': current['name'],
          '名册人数': current['studentCount'],
          '影响': '归档后停止名册调整和本班教师访问，保留学生档案及历史名册。',
          '恢复': '当前不支持重新启用，请确认班级已结束使用。'
        },
        reauth: reauth,
        actions: [
          DetailAction('确认归档', (dialog) async {
            sameWorkspace(root);
            await s.api.send('POST', '$root/classes/${current['id']}/archive',
                version: current['version'], key: key);
          }, destructive: true)
        ]);
    if (mounted && s.root == root) await open(current);
  }

  Future<void> act(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (s.tenant?['kind'] != 'ORGANIZATION') {
      return const Notice('班级与名册仅适用于机构工作空间。');
    }
    if (selected == null) {
      return ResourcePage(
        key: ValueKey('${s.root}-$archived'),
        api: s.api,
        path: '${s.root}/classes${archived ? '?includeArchived=true' : ''}',
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
                onSelected: (v) => setState(() => archived = v))
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
          onPressed: () => setState(() {
                selected = null;
                error = null;
              }),
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
          api: s.api,
          path: '${s.root}/classes/${c['id']}/students',
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
                  onPressed: () => context.go('/members'),
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
