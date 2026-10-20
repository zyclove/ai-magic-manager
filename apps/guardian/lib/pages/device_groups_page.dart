import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../core/api.dart';
import '../core/device_group_summary.dart';
import '../core/labels.dart';
import '../core/session.dart';
import '../ui/class_action_dialog.dart';
import '../ui/design.dart';
import '../ui/device_group_batch_picker.dart';
import '../ui/resource_page.dart';
import '../ui/owned_dialog_route.dart';
import 'device_subflow_scope.dart';

/// Institution inventory groups. Membership is never presented as a policy receipt.
class DeviceGroupsPage extends StatefulWidget {
  final Session session;
  const DeviceGroupsPage({super.key, required this.session});

  @override
  State<DeviceGroupsPage> createState() => _DeviceGroupsPageState();
}

class _DeviceGroupsPageState extends State<DeviceGroupsPage> {
  late final String root;
  late final DeviceSubflowScope pageScope;
  bool _active = true, _rebuildPending = false;
  final listKey = GlobalKey<ResourcePageState>();
  String? selectedId, nextMemberCursor, memberFilter;
  Json? detail;
  DeviceGroupSummary? summary;
  List<Json> members = const [];
  Object? error;
  bool loading = false, loadingMore = false, archived = false;
  int generation = 0;
  final dialogs = <OwnedDialogRoute<dynamic>>{};

  bool get current => mounted && _active &&
      widget.session.tenant != null && pageScope.current;

  @override
  void initState() {
    super.initState();
    root = widget.session.tenant == null ? '' : widget.session.root;
    final session = widget.session;
    pageScope = DeviceSubflowScope(session,
        permitted: () => mounted && _active &&
            identical(widget.session, session) && session.canOpen('device-groups'));
    pageScope.addListener(accessChanged);
  }

  void accessChanged() {
    if (current) return;
    generation++;
    closeDialogs();
    detail = null;
    summary = null;
    members = const [];
    selectedId = null;
    memberFilter = null;
    nextMemberCursor = null;
    loading = loadingMore = false;
    error = null;
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

  void closeDialogs() {
    final owned = dialogs.toList();
    dialogs.clear();
    if (owned.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final route in owned) {
        if (route.available) route.finish();
      }
    });
  }

  DeviceSubflowScope capture() {
    final capturedGeneration = generation, groupId = selectedId;
    return DeviceSubflowScope(widget.session,
        permitted: () => current && generation == capturedGeneration &&
            selectedId == groupId);
  }

  Future<T?> present<T>(DeviceSubflowScope scope,
      Widget Function(BuildContext, Api, bool Function()) builder,
      {bool barrierDismissible = false}) async {
    if (!current || !scope.current) return null;
    final parent = ModalRoute.of(context);
    var live = true, parentOpen = true;
    late final OwnedDialogRoute<T> route;
    late final Api api;
    bool available() => live && parentOpen && current && scope.current &&
        context.mounted && (parent == null || parent.isActive) &&
        route.available && route.isActive;
    route = OwnedDialogRoute<T>(context: context,
        barrierDismissible: barrierDismissible,
        builder: (context) => _GroupScopeView(scope: scope,
            hasAccess: available,
            builder: (context) => builder(context, api, available)));
    api = scope.api.scoped(available);
    dialogs.add(route);
    parent?.popped.then<void>((_) {
      parentOpen = false;
      if (!live) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (live && route.available) route.finish();
      });
    });
    try {
      final result = await presentOwnedDialog<T>(context, route);
      return current && scope.current && parentOpen &&
          (parent == null || parent.isActive) ? result : null;
    } finally {
      live = false;
      dialogs.remove(route);
    }
  }

  void reauth() {
    if (current) widget.session.login(stepUp: true);
  }

  @override
  void deactivate() {
    _active = false;
    closeDialogs();
    super.deactivate();
  }

  @override
  void dispose() {
    _active = false;
    generation++;
    closeDialogs();
    pageScope.removeListener(accessChanged);
    pageScope.dispose();
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
          !const {
            'CURRENT',
            'STALE_REGISTRATION',
            'DEVICE_INACTIVE',
            'PROFILE_ARCHIVED'
          }.contains(row['membershipStatus']) ||
          row['addedAt'] is! int) {
        throw const ApiFailure(502, 'INVALID_DEVICE_GROUP_RESPONSE');
      }
    }
    return List.unmodifiable(rows);
  }

  String membersPath(String id) =>
      '$root/device-groups/$id/devices${memberFilter == null ? '' : '?status=$memberFilter'}';

  Future<void> open(String id) async {
    if (!current) return;
    final revision = ++generation;
    if (selectedId != id) memberFilter = null;
    setState(() {
      selectedId = id;
      detail = null;
      summary = null;
      members = const [];
      nextMemberCursor = null;
      error = null;
      loading = true;
      loadingMore = false;
    });
    final scope = capture();
    try {
      final values = await Future.wait([
        scope.api.send('GET', '$root/device-groups/$id'),
        scope.api.page(membersPath(id)),
        scope.api.send('GET', '$root/device-groups/$id/summary')
      ]);
      if (!current || !scope.current || revision != generation) return;
      final group = validGroup(values[0], id);
      final page = values[1] as PageResult;
      final rows = validMembers(page.items);
      final health = DeviceGroupSummary.read(values[2], group);
      setState(() {
        detail = group;
        summary = health;
        members = rows;
        nextMemberCursor = page.nextCursor;
      });
    } catch (failure) {
      if (current && scope.current && revision == generation) {
        setState(() => error = failure);
      }
    } finally {
      if (current && scope.current && revision == generation) {
        setState(() => loading = false);
      }
      scope.dispose();
    }
  }

  Future<void> moreMembers() async {
    final id = selectedId, cursor = nextMemberCursor;
    if (!current || id == null || cursor == null || loadingMore) return;
    final scope = capture();
    setState(() => loadingMore = true);
    try {
      final page = await scope.api.page(membersPath(id), cursor: cursor);
      if (!current || !scope.current) return;
      if (page.items.any((item) =>
          members.any((old) => old['deviceId'] == item['deviceId']))) {
        throw const ApiFailure(502, 'INVALID_DEVICE_GROUP_RESPONSE');
      }
      final rows = validMembers(page.items);
      setState(() {
        members = List.unmodifiable([...members, ...rows]);
        nextMemberCursor = page.nextCursor;
      });
    } catch (failure) {
      if (current && scope.current) setState(() => error = failure);
    } finally {
      if (current && scope.current) setState(() => loadingMore = false);
      scope.dispose();
    }
  }

  void chooseFilter(String? status) {
    if (!current || selectedId == null || memberFilter == status) return;
    memberFilter = status;
    open(selectedId!);
  }

  Future<Json?> editName({Json? group}) async {
    if (!current) return null;
    final scope = capture();
    final id = group?['id'] as String?, version = group?['version'] as int?;
    final key = requestId();
    try {
      final result = await present<Json>(scope, (_, api, available) => ClassActionDialog(
          title: id == null ? '新建设备组' : '修改设备组名称',
          description: '设备组只整理本机构设备；关联设备不会自动下发或执行策略。',
          field: 'name',
          fieldLabel: '设备组名称',
          submitLabel: id == null ? '创建设备组' : '保存名称',
          initialName: group?['name'] as String?,
          accessChanges: scope,
          hasAccess: available,
          reauth: () { if (available()) reauth(); },
          onSubmit: (body) async => validGroup(await api.send(
              id == null ? 'POST' : 'PATCH',
              id == null ? '$root/device-groups' : '$root/device-groups/$id',
              body: body, version: version, key: key), id)));
      if (!current || !scope.current || result == null) return null;
      if (result['refresh'] == true) {
        if (id != null) await open(id);
        listKey.currentState?.load();
        return null;
      }
      return validGroup(result, id);
    } finally {
      scope.dispose();
    }
  }

  Future<void> create() async {
    if (!current) return;
    final group = await editName();
    if (current && group != null) await open(group['id'] as String);
  }

  Future<void> rename() async {
    final group = detail;
    if (!current || group == null) return;
    final updated = await editName(group: group);
    if (current && updated != null) await open(updated['id'] as String);
  }

  Future<Json?> pickDevice(DeviceSubflowScope scope) async {
    if (!current || !scope.current) return null;
    final chosen = await present<Json>(scope, (ctx, api, available) => Dialog(
        child: SizedBox(width: 760, height: 620,
            child: SingleChildScrollView(padding: const EdgeInsets.all(18),
                child: ResourcePage(
                    title: '选择本机构设备',
                    subtitle: '只可加入已激活设备；按页浏览，不用名称匹配身份。',
                    path: '$root/devices', api: api,
                    columns: [
                      ColumnSpec('设备', (row) => Text('${row['displayName']}')),
                      ColumnSpec('平台', (row) => Text(label(row['platform']))),
                      ColumnSpec('状态', (row) => Text(label(row['state'])))
                    ],
                    onOpen: (row) async {
                      if (!ctx.mounted || !available()) return;
                      final route = ModalRoute.of(ctx);
                      if (route?.isCurrent != true) return;
                      if (row['state'] != 'ACTIVE') {
                        toast(ctx, '此设备尚未激活，不能加入设备组。');
                        return;
                      }
                      if (route is OwnedDialogRoute<Json>) route.finish(row);
                    })))));
    if (!current || !scope.current || chosen == null) return null;
    if (chosen['id'] is! String || chosen['registrationId'] is! String) {
      throw const ApiFailure(502, 'INVALID_DEVICE_GROUP_RESPONSE');
    }
    return chosen;
  }

  Future<void> addDevice() async {
    if (!current || detail == null) return;
    final scope = capture(), group = Map<String, dynamic>.of(detail!);
    try {
      final chosen = await pickDevice(scope);
      if (!current || !scope.current || chosen == null) return;
      final key = requestId();
      final result = await confirm(scope: scope,
          title: '加入设备组',
          description:
              '将“${chosen['displayName']}”关联到“${group['name']}”。设备组关联不改变设备当前规则或系统权限。',
          submit: '确认加入',
          operation: (api) => api.send(
              'POST', '$root/device-groups/${group['id']}/devices',
              body: {'deviceId': chosen['id'],
                'registrationId': chosen['registrationId']},
              version: group['version'] as int, key: key));
      if (current && scope.current && result != null) {
        await open(group['id'] as String);
      }
    } catch (failure) {
      if (current && scope.current) setState(() => error = failure);
    } finally {
      scope.dispose();
    }
  }

  Future<void> addDevices() async {
    if (!current || detail == null) return;
    final scope = capture(), group = Map<String, dynamic>.of(detail!);
    try {
      final chosen = await present<List<Json>>(scope,
          (_, api, available) => DeviceGroupBatchPicker(api: api, root: root,
              current: available, accessChanges: scope));
      if (!current || !scope.current || chosen == null || chosen.isEmpty) return;
      final key = requestId();
      final names = chosen.take(3).map((row) => row['displayName']).join('、');
      final suffix = chosen.length > 3 ? '等' : '';
      final result = await confirm(scope: scope,
          title: '批量加入设备组',
          description:
              '将 $names$suffix ${chosen.length} 台设备加入“${group['name']}”。整批会以当前组版本核对，任一设备注册周期或状态变化都不会提交。设备组关联不改变设备规则。',
          submit: '确认加入 ${chosen.length} 台',
          operation: (api) => api.send('POST',
              '$root/device-groups/${group['id']}/devices/batches',
              body: {'devices': chosen.map((row) => {
                'deviceId': row['id'], 'registrationId': row['registrationId']
              }).toList()}, version: group['version'] as int, key: key));
      if (current && scope.current && result != null) {
        await open(group['id'] as String);
      }
    } finally {
      scope.dispose();
    }
  }

  Future<void> removeDevices() async {
    if (!current || detail == null) return;
    final scope = capture(), group = Map<String, dynamic>.of(detail!);
    try {
      final chosen = await present<List<Json>>(scope,
          (_, api, available) => DeviceGroupBatchPicker(api: api, root: root,
              groupId: group['id'] as String,
              current: available, accessChanges: scope));
      if (!current || !scope.current || chosen == null || chosen.isEmpty) return;
      final key = requestId();
      final names = chosen.take(3).map((row) => row['displayName']).join('、');
      final suffix = chosen.length > 3 ? '等' : '';
      final result = await confirm(scope: scope,
          title: '批量移出设备组',
          description:
              '将 $names$suffix ${chosen.length} 台设备从“${group['name']}”移出。整批按当前组版本及原注册周期核对；不会撤销设备注册或已发布的独立配置。',
          submit: '确认移出 ${chosen.length} 台',
          operation: (api) => api.send('POST',
              '$root/device-groups/${group['id']}/devices/removals',
              body: {'devices': chosen.map((row) => {
                'deviceId': row['deviceId'],
                'registrationId': row['registrationId']
              }).toList()}, version: group['version'] as int, key: key));
      if (current && scope.current && result != null) {
        await open(group['id'] as String);
      }
    } finally {
      scope.dispose();
    }
  }

  Future<void> removeDevice(Json member) async {
    if (!current || detail == null) return;
    final scope = capture(), group = Map<String, dynamic>.of(detail!);
    final key = requestId();
    final path = '$root/device-groups/${group['id']}/devices/${member['deviceId']}'
        '?registrationId=${Uri.encodeQueryComponent(member['registrationId'] as String)}';
    try {
      final result = await confirm(scope: scope,
          title: '移出设备组',
          description:
              '将“${member['displayName']}”从“${group['name']}”移出。此操作不解除设备注册，也不撤销现有独立策略。',
          submit: '确认移出',
          operation: (api) => api.send('DELETE', path,
              version: group['version'] as int, key: key));
      if (current && scope.current && result != null) {
        await open(group['id'] as String);
      }
    } finally {
      scope.dispose();
    }
  }

  Future<void> archive() async {
    if (!current || detail == null) return;
    final scope = capture(), group = Map<String, dynamic>.of(detail!);
    final key = requestId();
    try {
      final result = await confirm(scope: scope,
          title: '归档设备组',
          description: '归档“${group['name']}”后不能继续修改成员。成员历史会保留；后续批量策略必须排除归档组。',
          submit: '确认归档',
          operation: (api) => api.send('POST',
              '$root/device-groups/${group['id']}/archive',
              version: group['version'] as int, key: key));
      if (current && scope.current && result != null) {
        await open(group['id'] as String);
      }
    } finally {
      scope.dispose();
    }
  }

  Future<Json?> confirm(
      {required DeviceSubflowScope scope,
      required String title,
      required String description,
      required String submit,
      required Future<dynamic> Function(Api) operation}) async {
    if (!current || !scope.current || selectedId == null) return null;
    final groupId = selectedId!;
    final result = await present<Json>(scope, (_, api, available) => _GroupConfirmDialog(
        title: title, description: description, submit: submit,
        accessChanges: scope,
        hasAccess: available,
        reauth: () { if (available()) reauth(); },
        operation: () async {
          if (!available() || selectedId != groupId) {
            throw const ApiFailure(409, 'WORKSPACE_CHANGED');
          }
          final response = await operation(api);
          if (!available() || selectedId != groupId) {
            throw const ApiFailure(409, 'WORKSPACE_CHANGED');
          }
          return validGroup(response, groupId);
        }));
    if (!current || !scope.current) return null;
    if (result?['refresh'] == true) {
      await open(groupId);
      return null;
    }
    return result;
  }

  Widget healthPanel() {
    final counts = summary!;
    final total = counts.total;
    final usable = counts.current;
    Widget filterChip(String? status, String title, int count) => ChoiceChip(
          label: Text('$title $count'),
          selected: memberFilter == status,
          onSelected: (_) => chooseFilter(status),
        );
    return Panel(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('成员关联状态', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 6),
      const Text('统计覆盖整个设备组。关联有效仅表示当前注册身份可用于目标选择，不代表策略已在设备执行。'),
      const SizedBox(height: 16),
      Semantics(
          label: '关联有效 $usable 台，共 $total 台',
          child: LinearProgressIndicator(
              value: total == 0 ? 0 : usable / total,
              minHeight: 8,
              backgroundColor: const Color(0xFFE8EDF3),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF00886C)))),
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        filterChip(null, '全部', total),
        filterChip('CURRENT', '关联有效', usable),
        filterChip('STALE_REGISTRATION', '旧注册周期', counts.staleRegistration),
        filterChip('DEVICE_INACTIVE', '设备未激活', counts.deviceInactive),
        filterChip('PROFILE_ARCHIVED', '档案已归档', counts.profileArchived),
      ])
    ]));
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
          api: pageScope.api,
          notice: '设备组只保存关联关系，不会自行限制应用、下发策略或证明系统执行。',
          emptyTitle: '暂无设备组',
          emptyDescription: '创建一个分组，再关联本机构已激活的设备。',
          createLabel: '新建设备组',
          create: create,
          reauth: reauth,
          toolbar: [
            FilterChip(
                label: const Text('包含已归档'),
                selected: archived,
                onSelected: (value) {
                  if (current) setState(() => archived = value);
                })
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
              onPressed: () {
                if (!current) return;
                setState(() {
                  selectedId = null;
                  detail = null;
                  summary = null;
                  memberFilter = null;
                  members = const [];
                  nextMemberCursor = null;
                  loading = loadingMore = false;
                  error = null;
                  generation++;
                });
              },
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回列表'))),
      const Notice('分组成员不是策略执行回执；归档、移出设备也不会自动撤销其他独立策略。'),
      const SizedBox(height: 16),
      if (loading) const LinearProgressIndicator(),
      if (error != null)
        Panel(
            child: FailureView(error!,
                retry: selectedId == null ? null : () => open(selectedId!),
                reauth: reauth)),
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
                  onPressed: addDevices,
                  icon: const Icon(Icons.playlist_add_check),
                  label: const Text('批量加入')),
              OutlinedButton.icon(
                  onPressed: removeDevices,
                  icon: const Icon(Icons.playlist_remove),
                  label: const Text('批量移出')),
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
        if (summary != null) ...[healthPanel(), const SizedBox(height: 16)],
        Panel(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              Text('组内设备', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              if (summary != null && summary!.excluded > 0)
                const Notice('部分成员关联已失效，不会进入设备组策略目标。请核对注册周期后移出旧成员。',
                    warning: true),
              if (members.isEmpty)
                EmptyView(
                    memberFilter == null ? '组内暂无设备' : '此状态下暂无设备',
                    memberFilter == null
                        ? '从已激活的机构设备清单中选择并加入。'
                        : '可切换上方状态查看其他成员。'),
              for (final member in members)
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${member['displayName']}'),
                    subtitle: Text(
                        '${label(member['platform'])} · ${label(member['state'])} · ${label(member['membershipStatus'])}\n设备 ${member['deviceId']} · 注册 ${member['registrationId']}'),
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

/// All selectors hide their private contents before a revoked route is removed.
class _GroupScopeView extends StatefulWidget {
  final DeviceSubflowScope scope;
  final WidgetBuilder builder;
  final bool Function() hasAccess;
  const _GroupScopeView({required this.scope, required this.builder,
      required this.hasAccess});

  @override
  State<_GroupScopeView> createState() => _GroupScopeViewState();
}

class _GroupScopeViewState extends State<_GroupScopeView> {
  bool _revoked = false, _active = true, _rebuildPending = false;
  ModalRoute<dynamic>? _route;

  bool get permitted {
    if (!widget.scope.current || !widget.hasAccess()) _revoked = true;
    return !_revoked;
  }

  void changed() {
    final wasRevoked = _revoked;
    permitted;
    if (wasRevoked || !_revoked || !mounted || !_active) return;
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
  void initState() {
    super.initState();
    _revoked = !widget.scope.current || !widget.hasAccess();
    widget.scope.addListener(changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    _active = false;
    _revoked = true;
    widget.scope.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => permitted
      ? widget.builder(context)
      : AlertDialog(
          title: const Text('工作空间或权限已变化'),
          content: const Text('已隐藏原操作内容。请关闭窗口，在当前工作空间重新打开。'),
          actions: [TextButton(onPressed: () {
            final route = _route;
            if (!mounted || !_active || route?.isCurrent != true) return;
            if (route is OwnedDialogRoute<dynamic>) route.finish();
          }, child: const Text('关闭'))]);
}

/// Fixed-input confirmation retains the same idempotency key on uncertain retry.
class _GroupConfirmDialog extends StatefulWidget {
  final String title, description, submit;
  final Future<Json> Function() operation;
  final VoidCallback reauth;
  final Listenable accessChanges;
  final bool Function() hasAccess;
  const _GroupConfirmDialog(
      {required this.title,
      required this.description,
      required this.submit,
      required this.operation,
      required this.reauth,
      required this.accessChanges,
      required this.hasAccess});

  @override
  State<_GroupConfirmDialog> createState() => _GroupConfirmDialogState();
}

class _GroupConfirmDialogState extends State<_GroupConfirmDialog> {
  bool busy = false, uncertain = false;
  Object? error;
  ModalRoute<dynamic>? _route;
  bool _active = true, _revoked = false, _rebuildPending = false;

  bool get versionConflict =>
      error is ApiFailure && (error as ApiFailure).status == 412;

  void _observeAccess() {
    if (!_revoked && !widget.hasAccess()) _revoked = true;
  }

  bool get permitted {
    _observeAccess();
    return !_revoked;
  }

  bool get current =>
      mounted && _active && permitted && _route?.isCurrent == true &&
      (_route is! OwnedDialogRoute<dynamic> ||
          (_route as OwnedDialogRoute<dynamic>).available);

  void _accessChanged() {
    final wasRevoked = _revoked;
    _observeAccess();
    if (wasRevoked || !_revoked || !mounted || !_active) return;
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

  void finish([Json? result]) {
    if (!mounted || !_active) return;
    final route = _route;
    if (route is OwnedDialogRoute<Json>) {
      route.finish(result);
    } else if (route?.isCurrent == true) {
      route!.navigator?.pop(result);
    }
  }

  void close() {
    if (current && !busy) {
      finish(uncertain || versionConflict
          ? <String, dynamic>{'refresh': true} : null);
    }
  }

  void reauthenticate() {
    if (current && !busy) widget.reauth();
  }

  @override
  void initState() {
    super.initState();
    _observeAccess();
    widget.accessChanges.addListener(_accessChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ModalRoute.of(context);
    if (_route != null && !identical(_route, next)) _revoked = true;
    _route = next;
  }

  @override
  void didUpdateWidget(_GroupConfirmDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.accessChanges, widget.accessChanges)) {
      oldWidget.accessChanges.removeListener(_accessChanged);
      widget.accessChanges.addListener(_accessChanged);
    }
    _observeAccess();
  }

  @override
  void deactivate() {
    _active = false;
    _revoked = true;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void dispose() {
    _active = false;
    _revoked = true;
    widget.accessChanges.removeListener(_accessChanged);
    super.dispose();
  }

  Future<void> submit() async {
    if (!current || busy || versionConflict) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.operation();
      if (mounted && _active && permitted) finish(result);
    } catch (failure) {
      if (mounted && _active && permitted) {
        setState(() {
          error = failure;
          uncertain = failure is! ApiFailure ||
              failure.status == 0 || failure.status >= 500;
        });
      }
    } finally {
      if (mounted && _active) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => !permitted
      ? AlertDialog(
          title: const Text('工作空间或权限已变化'),
          content: const Text('已隐藏原操作内容。请关闭窗口，在当前工作空间重新打开。'),
          actions: [TextButton(onPressed: () {
            if (_route?.isCurrent == true) finish();
          }, child: const Text('关闭'))])
      : PopScope(
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
                      FailureView(error!, reauth: reauthenticate)
                    ],
                    if (uncertain) ...[
                      const SizedBox(height: 12),
                      const Text('提交结果未确认，已保留原请求。请重试原提交，或关闭后刷新记录。')
                    ]
                  ])),
          actions: [
            TextButton(
                onPressed: busy ? null : close,
                child: const Text('关闭')),
            FilledButton(
                onPressed: busy || versionConflict
                    ? null
                    : submit,
                child: Text(busy
                    ? '提交中…'
                    : uncertain
                        ? '重试原提交'
                        : widget.submit))
          ]));
}
