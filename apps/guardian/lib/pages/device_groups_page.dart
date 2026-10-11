import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/session.dart';
import '../ui/class_action_dialog.dart';
import '../ui/design.dart';
import '../ui/resource_page.dart';

/// Institution inventory groups. Membership is never presented as a policy receipt.
class DeviceGroupsPage extends StatefulWidget {
  final Session session;
  const DeviceGroupsPage({super.key, required this.session});

  @override
  State<DeviceGroupsPage> createState() => _DeviceGroupsPageState();
}

class _DeviceGroupsPageState extends State<DeviceGroupsPage> {
  late final String root, actor, role;
  final listKey = GlobalKey<ResourcePageState>();
  String? selectedId, nextMemberCursor;
  Json? detail;
  List<Json> members = const [];
  Object? error;
  bool loading = false, loadingMore = false, archived = false;
  int generation = 0;
  ModalRoute<dynamic>? dialog;

  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.tenant != null &&
      widget.session.root == root &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role &&
      widget.session.canOpen('device-groups');

  @override
  void initState() {
    super.initState();
    root = widget.session.root;
    actor = widget.session.profile!['subject'] as String;
    role = widget.session.role;
    widget.session.addListener(accessChanged);
  }

  void accessChanged() {
    if (!current) {
      generation++;
      closeDialog();
      if (mounted) {
        setState(() {
          detail = null;
          members = const [];
          selectedId = null;
          error = null;
        });
      }
    }
  }

  void closeDialog() {
    final route = dialog;
    dialog = null;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive && route.navigator?.mounted == true) {
        route.navigator!.removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    generation++;
    closeDialog();
    widget.session.removeListener(accessChanged);
    super.dispose();
  }

  Json validGroup(dynamic value, [String? expectedId]) {
    if (value is! Json ||
        value['id'] is! String ||
        (expectedId != null && value['id'] != expectedId) ||
        value['name'] is! String ||
        !const {'ACTIVE', 'ARCHIVED'}.contains(value['state']) ||
        value['version'] is! int ||
        value['version'] < 0 ||
        value['deviceCount'] is! int ||
        value['deviceCount'] < 0 ||
        value['deviceCount'] > 5000) {
      throw const ApiFailure(502, 'INVALID_DEVICE_GROUP_RESPONSE');
    }
    return value;
  }

  List<Json> validMembers(List<Json> rows) {
    final seen = <String>{};
    for (final row in rows) {
      if (row['deviceId'] is! String ||
          !seen.add(row['deviceId']) ||
          row['registrationId'] is! String ||
          row['displayName'] is! String ||
          row['platform'] is! String ||
          row['state'] is! String ||
          row['addedAt'] is! int) {
        throw const ApiFailure(502, 'INVALID_DEVICE_GROUP_RESPONSE');
      }
    }
    return List.unmodifiable(rows);
  }

  Future<void> open(String id) async {
    if (!current) return;
    final revision = ++generation;
    setState(() {
      selectedId = id;
      detail = null;
      members = const [];
      nextMemberCursor = null;
      error = null;
      loading = true;
    });
    try {
      final values = await Future.wait([
        widget.session.api.send('GET', '$root/device-groups/$id'),
        widget.session.api.page('$root/device-groups/$id/devices')
      ]);
      if (!current || revision != generation) return;
      final group = validGroup(values[0], id);
      final page = values[1] as PageResult;
      final rows = validMembers(page.items);
      setState(() {
        detail = group;
        members = rows;
        nextMemberCursor = page.nextCursor;
      });
    } catch (failure) {
      if (current && revision == generation) setState(() => error = failure);
    } finally {
      if (current && revision == generation) setState(() => loading = false);
    }
  }

  Future<void> moreMembers() async {
    final id = selectedId, cursor = nextMemberCursor;
    if (!current || id == null || cursor == null || loadingMore) return;
    final revision = generation;
    setState(() => loadingMore = true);
    try {
      final page = await widget.session.api
          .page('$root/device-groups/$id/devices', cursor: cursor);
      if (!current || revision != generation) return;
      if (page.items.any((item) =>
          members.any((old) => old['deviceId'] == item['deviceId']))) {
        throw const ApiFailure(502, 'INVALID_DEVICE_GROUP_RESPONSE');
      }
      final rows = validMembers(page.items);
      setState(() {
        members = List.unmodifiable([...members, ...rows]);
        nextMemberCursor = page.nextCursor;
        error = null;
      });
    } catch (failure) {
      if (current && revision == generation) setState(() => error = failure);
    } finally {
      if (current && revision == generation) {
        setState(() => loadingMore = false);
      }
    }
  }

  Future<Json?> editName({Json? group}) async {
    if (!current) return null;
    final id = group?['id'] as String?, version = group?['version'] as int?;
    final key = requestId();
    final result = await showDialog<Json>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          dialog = ModalRoute.of(ctx);
          return ClassActionDialog(
              title: id == null ? '新建设备组' : '修改设备组名称',
              description: '设备组只整理本机构设备；关联设备不会自动下发或执行策略。',
              field: 'name',
              fieldLabel: '设备组名称',
              submitLabel: id == null ? '创建设备组' : '保存名称',
              initialName: group?['name'] as String?,
              reauth: () => widget.session.login(stepUp: true),
              onSubmit: (body) async {
                if (!current) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
                final response = await widget.session.api.send(
                    id == null ? 'POST' : 'PATCH',
                    id == null
                        ? '$root/device-groups'
                        : '$root/device-groups/$id',
                    body: body,
                    version: version,
                    key: key);
                return validGroup(response, id);
              });
        });
    dialog = null;
    if (!current || result == null) return null;
    if (result['refresh'] == true) {
      if (id != null) await open(id);
      listKey.currentState?.load();
      return null;
    }
    return validGroup(result, id);
  }

  Future<void> create() async {
    final group = await editName();
    if (current && group != null) await open(group['id'] as String);
  }

  Future<void> rename() async {
    final group = detail;
    if (group == null) return;
    final updated = await editName(group: group);
    if (current && updated != null) await open(updated['id'] as String);
  }

  Future<Json?> pickDevice() async {
    if (!current) return null;
    final chosen = await showDialog<Json>(
        context: context,
        builder: (ctx) {
          dialog = ModalRoute.of(ctx);
          return Dialog(
              child: SizedBox(
                  width: 760,
                  height: 620,
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.all(18),
                      child: ResourcePage(
                          title: '选择本机构设备',
                          subtitle: '只可加入已激活设备；按页浏览，不用名称匹配身份。',
                          path: '$root/devices',
                          api: widget.session.api,
                          columns: [
                            ColumnSpec(
                                '设备', (r) => Text('${r['displayName']}')),
                            ColumnSpec('平台', (r) => Text(label(r['platform']))),
                            ColumnSpec('状态', (r) => Text(label(r['state'])))
                          ],
                          onOpen: (row) async {
                            if (!current) return;
                            if (row['state'] != 'ACTIVE') {
                              toast(ctx, '此设备尚未激活，不能加入设备组。');
                              return;
                            }
                            Navigator.of(ctx).pop(row);
                          }))));
        });
    dialog = null;
    if (!current || chosen == null) return null;
    if (chosen['id'] is! String || chosen['registrationId'] is! String) {
      throw const ApiFailure(502, 'INVALID_DEVICE_GROUP_RESPONSE');
    }
    return chosen;
  }

  Future<void> addDevice() async {
    if (!current || detail == null) return;
    Json? chosen;
    try {
      chosen = await pickDevice();
    } catch (failure) {
      if (current) setState(() => error = failure);
      return;
    }
    if (!current || chosen == null || detail == null) return;
    final group = Map<String, dynamic>.of(detail!);
    final key = requestId();
    final result = await confirm(
        title: '加入设备组',
        description:
            '将“${chosen['displayName']}”关联到“${group['name']}”。设备组关联不改变设备当前规则或系统权限。',
        submit: '确认加入',
        operation: () => widget.session.api.send(
            'POST', '$root/device-groups/${group['id']}/devices',
            body: {
              'deviceId': chosen!['id'],
              'registrationId': chosen['registrationId']
            },
            version: group['version'] as int,
            key: key));
    if (current && result != null) await open(group['id'] as String);
  }

  Future<void> removeDevice(Json member) async {
    if (!current || detail == null) return;
    final group = Map<String, dynamic>.of(detail!);
    final key = requestId();
    final path =
        '$root/device-groups/${group['id']}/devices/${member['deviceId']}'
        '?registrationId=${Uri.encodeQueryComponent(member['registrationId'] as String)}';
    final result = await confirm(
        title: '移出设备组',
        description:
            '将“${member['displayName']}”从“${group['name']}”移出。此操作不解除设备注册，也不撤销现有独立策略。',
        submit: '确认移出',
        operation: () => widget.session.api
            .send('DELETE', path, version: group['version'] as int, key: key));
    if (current && result != null) await open(group['id'] as String);
  }

  Future<void> archive() async {
    if (!current || detail == null) return;
    final group = Map<String, dynamic>.of(detail!);
    final key = requestId();
    final result = await confirm(
        title: '归档设备组',
        description: '归档“${group['name']}”后不能继续修改成员。成员历史会保留；后续批量策略必须排除归档组。',
        submit: '确认归档',
        operation: () => widget.session.api.send(
            'POST', '$root/device-groups/${group['id']}/archive',
            version: group['version'] as int, key: key));
    if (current && result != null) await open(group['id'] as String);
  }

  Future<Json?> confirm(
      {required String title,
      required String description,
      required String submit,
      required Future<dynamic> Function() operation}) async {
    if (!current || selectedId == null) return null;
    final groupId = selectedId!;
    final result = await showDialog<Json>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          dialog = ModalRoute.of(ctx);
          return _GroupConfirmDialog(
              title: title,
              description: description,
              submit: submit,
              reauth: () => widget.session.login(stepUp: true),
              operation: () async {
                if (!current || selectedId != groupId) {
                  throw const ApiFailure(409, 'WORKSPACE_CHANGED');
                }
                final response = await operation();
                if (!current || selectedId != groupId) {
                  throw const ApiFailure(409, 'WORKSPACE_CHANGED');
                }
                return validGroup(response, groupId);
              });
        });
    dialog = null;
    if (current && result?['refresh'] == true && selectedId != null) {
      await open(selectedId!);
    }
    return current ? result : null;
  }

  @override
  Widget build(BuildContext context) {
    if (!current) {
      return const Panel(child: EmptyView('机构范围已变化', '请重新打开设备组页面。'));
    }
    if (selectedId == null) {
      return ResourcePage(
          key: listKey,
          title: '机构设备组',
          subtitle: '整理设备与未来批量策略的目标范围。',
          path: '$root/device-groups?includeArchived=$archived',
          api: widget.session.api,
          notice: '设备组只保存关联关系，不会自行限制应用、下发策略或证明系统执行。',
          emptyTitle: '暂无设备组',
          emptyDescription: '创建一个分组，再关联本机构已激活的设备。',
          createLabel: '新建设备组',
          create: create,
          reauth: () => widget.session.login(stepUp: true),
          toolbar: [
            FilterChip(
                label: const Text('包含已归档'),
                selected: archived,
                onSelected: (value) => setState(() => archived = value))
          ],
          columns: [
            ColumnSpec('名称', (r) => Text('${r['name']}')),
            ColumnSpec(
                '状态', (r) => Text(r['state'] == 'ACTIVE' ? '使用中' : '已归档')),
            ColumnSpec('设备数', (r) => Text('${r['deviceCount']} 台'))
          ],
          onOpen: (row) => open(row['id'] as String));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeading('设备组详情', '核对设备身份和注册周期后调整分组。',
          action: OutlinedButton.icon(
              onPressed: () => setState(() {
                    selectedId = null;
                    detail = null;
                    members = const [];
                    generation++;
                  }),
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回列表'))),
      const Notice('分组成员不是策略执行回执；归档、移出设备也不会自动撤销其他独立策略。'),
      const SizedBox(height: 16),
      if (loading) const LinearProgressIndicator(),
      if (error != null)
        Panel(
            child: FailureView(error!,
                retry: selectedId == null ? null : () => open(selectedId!),
                reauth: () => widget.session.login(stepUp: true))),
      if (detail != null) ...[
        Panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${detail!['name']}',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          SelectableText('编号 ${detail!['id']} · 版本 ${detail!['version']}'),
          Text(
              '状态 ${detail!['state'] == 'ACTIVE' ? '使用中' : '已归档'} · ${detail!['deviceCount']} 台设备'),
          const SizedBox(height: 16),
          if (detail!['state'] == 'ACTIVE')
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                  onPressed: addDevice,
                  icon: const Icon(Icons.add),
                  label: const Text('加入设备')),
              OutlinedButton.icon(
                  onPressed: rename,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('修改名称')),
              OutlinedButton.icon(
                  onPressed: archive,
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('归档设备组'))
            ])
        ])),
        const SizedBox(height: 16),
        Panel(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              Text('组内设备', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              if (members.isEmpty)
                const EmptyView('组内暂无设备', '从已激活的机构设备清单中选择并加入。'),
              for (final member in members)
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${member['displayName']}'),
                    subtitle: Text(
                        '${label(member['platform'])} · ${label(member['state'])}\n设备 ${member['deviceId']} · 注册 ${member['registrationId']}'),
                    isThreeLine: true,
                    trailing: detail!['state'] == 'ACTIVE'
                        ? IconButton(
                            tooltip: '移出 ${member['displayName']}',
                            onPressed: () => removeDevice(member),
                            icon: const Icon(Icons.remove_circle_outline))
                        : null),
              if (loadingMore) const LinearProgressIndicator(),
              if (nextMemberCursor != null)
                TextButton.icon(
                    onPressed: loadingMore ? null : moreMembers,
                    icon: const Icon(Icons.expand_more),
                    label: const Text('加载更多设备'))
            ]))
      ]
    ]);
  }
}

/// Fixed-input confirmation retains the same idempotency key on uncertain retry.
class _GroupConfirmDialog extends StatefulWidget {
  final String title, description, submit;
  final Future<Json> Function() operation;
  final VoidCallback reauth;
  const _GroupConfirmDialog(
      {required this.title,
      required this.description,
      required this.submit,
      required this.operation,
      required this.reauth});

  @override
  State<_GroupConfirmDialog> createState() => _GroupConfirmDialogState();
}

class _GroupConfirmDialogState extends State<_GroupConfirmDialog> {
  bool busy = false, uncertain = false;
  Object? error;

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.operation();
      if (mounted) Navigator.pop(context, result);
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = failure;
          uncertain = failure is ApiFailure &&
              (failure.status == 0 || failure.status >= 500);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: AlertDialog(
          title: Text(widget.title),
          content: SizedBox(
              width: 480,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.description),
                    if (error != null) ...[
                      const SizedBox(height: 16),
                      FailureView(error!, reauth: widget.reauth)
                    ],
                    if (uncertain) ...[
                      const SizedBox(height: 12),
                      const Text('提交结果未确认，已保留原请求。请重试原提交，或关闭后刷新记录。')
                    ]
                  ])),
          actions: [
            TextButton(
                onPressed: busy
                    ? null
                    : () => Navigator.pop(
                        context,
                        uncertain ||
                                error is ApiFailure &&
                                    (error as ApiFailure).status == 412
                            ? <String, dynamic>{'refresh': true}
                            : null),
                child: const Text('关闭')),
            FilledButton(
                onPressed: busy ||
                        error is ApiFailure &&
                            (error as ApiFailure).status == 412
                    ? null
                    : submit,
                child: Text(busy
                    ? '提交中…'
                    : uncertain
                        ? '重试原提交'
                        : widget.submit))
          ]));
}
