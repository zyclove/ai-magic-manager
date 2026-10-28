import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:uuid/uuid.dart';
import '../core/api.dart';
import '../core/device_group_summary.dart';
import '../core/device_group_change.dart';
import '../core/labels.dart';
import '../core/session.dart';
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
  bool _active = true, _rebuildPending = false, pageReadDenied = false;
  final listKey = GlobalKey<ResourcePageState>();
  String? selectedId, nextMemberCursor, memberFilter;
  Json? detail;
  DeviceGroupSummary? summary;
  List<Json> members = const [];
  Object? error, memberPageError;
  bool memberCursorInvalid = false;
  bool loading = false, loadingMore = false, archived = false;
  bool showingPrevious = false;
  int generation = 0;
  Object? activeAction;
  bool get acting => activeAction != null;
  final dialogs = <OwnedDialogRoute<dynamic>>{};

  bool get current =>
      mounted &&
      _active &&
      !pageReadDenied &&
      widget.session.tenant != null &&
      pageScope.current;

  @override
  void initState() {
    super.initState();
    root = widget.session.tenant == null ? '' : widget.session.root;
    final session = widget.session;
    pageScope = DeviceSubflowScope(session,
        permitted: () =>
            mounted &&
            _active &&
            !pageReadDenied &&
            identical(widget.session, session) &&
            session.canOpen('device-groups'));
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
    showingPrevious = false;
    error = memberPageError = null;
    memberCursorInvalid = false;
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

  // Only a rejection of the still-current request can retire this page capture.
  // Local scope failures and late responses must not revoke a newer view.
  bool rejectPrivateAccess(Object failure, bool Function() available) {
    if (!current ||
        !available() ||
        failure is! ApiFailure ||
        (failure.status != 403 &&
            failure.code != 'WORKSPACE_CHANGED' &&
            (failure.status != 401 || failure.code == 'REAUTH_REQUIRED'))) {
      return false;
    }
    pageReadDenied = true;
    accessChanged();
    return true;
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
        permitted: () =>
            current &&
            generation == capturedGeneration &&
            selectedId == groupId);
  }

  Future<T?> present<T>(DeviceSubflowScope scope,
      Widget Function(BuildContext, Api, bool Function()) builder,
      {bool barrierDismissible = false, ResourceActionLease? owner}) async {
    if (!current || !scope.current) return null;
    final changes = Listenable.merge([scope, if (owner != null) owner]);
    final parent = ModalRoute.of(context);
    var live = true, parentOpen = true;
    late final OwnedDialogRoute<T> route;
    late final Api api;
    bool available() =>
        live &&
        parentOpen &&
        current &&
        scope.current &&
        (owner == null || owner.current) &&
        context.mounted &&
        (parent == null || parent.isActive) &&
        route.available &&
        route.isActive;
    route = OwnedDialogRoute<T>(
        context: context,
        barrierDismissible: barrierDismissible,
        builder: (context) => _GroupScopeView(
            scope: scope,
            changes: changes,
            hasAccess: available,
            builder: (context) => builder(context, api, available)));
    api = _GroupDialogApi(scope.api.scoped(available), (failure) {
      rejectPrivateAccess(failure, available);
    });
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
      return current &&
              scope.current &&
              (owner == null || owner.current) &&
              parentOpen &&
              (parent == null || parent.isActive)
          ? result
          : null;
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

  Json validGroup(dynamic value, [String? expectedId]) =>
      readDeviceGroupSnapshot(value, expectedId: expectedId);

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

  Future<void> open(String id, {bool keepLoaded = true}) async {
    if (!current || (loading && selectedId == id && keepLoaded)) return;
    final preserve =
        keepLoaded && selectedId == id && detail != null && summary != null;
    final revision = ++generation;
    if (selectedId != id) memberFilter = null;
    setState(() {
      selectedId = id;
      if (!preserve) {
        detail = null;
        summary = null;
        members = const [];
        nextMemberCursor = null;
      }
      showingPrevious = preserve;
      error = null;
      memberPageError = null;
      memberCursorInvalid = false;
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
        showingPrevious = false;
      });
    } catch (failure) {
      if (current &&
          scope.current &&
          revision == generation &&
          !rejectPrivateAccess(
              failure, () => scope.current && revision == generation)) {
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
    if (!current ||
        id == null ||
        cursor == null ||
        loading ||
        loadingMore ||
        acting ||
        showingPrevious) return;
    final scope = capture();
    setState(() {
      loadingMore = true;
      memberPageError = null;
    });
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
      if (current &&
          scope.current &&
          !rejectPrivateAccess(failure, () => scope.current)) {
        setState(() {
          memberPageError = failure;
          if (failure is ApiFailure && failure.code == 'INVALID_CURSOR') {
            nextMemberCursor = null;
            memberCursorInvalid = true;
          }
        });
      }
    } finally {
      if (current && scope.current) setState(() => loadingMore = false);
      scope.dispose();
    }
  }

  void chooseFilter(String? status) {
    if (!current || acting || selectedId == null || memberFilter == status) {
      return;
    }
    memberFilter = status;
    open(selectedId!, keepLoaded: false);
  }

  bool needsReview(Object failure) =>
      failure is! ApiFailure ||
      failure.status == 0 ||
      failure.status == 408 ||
      failure.status >= 500 ||
      failure.status == 412 ||
      isUnavailableOperationResult(failure);

  Future<Json> sendChange(BuildContext dialog, Api api,
      bool Function() available, DeviceGroupChange change, String key,
      {required bool query}) async {
    if (!available()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    final (method, path) = switch (change.operation) {
      'CREATE' => ('POST', '$root/device-groups'),
      'RENAME' => ('PATCH', '$root/device-groups/${change.groupId}'),
      'ARCHIVE' => ('POST', '$root/device-groups/${change.groupId}/archive'),
      'ADD' => (
          'POST',
          '$root/device-groups/${change.groupId}/devices/batches'
        ),
      'REMOVE' => (
          'POST',
          '$root/device-groups/${change.groupId}/devices/removals'
        ),
      _ => throw const ApiFailure(400, 'VALIDATION_FAILED'),
    };
    final raw = await api.send(query ? 'POST' : method,
        query ? '$root/device-groups/operation-results/$key/query' : path,
        body: query
            ? change.queryBody
            : change.operation == 'ARCHIVE'
                ? null
                : change.body,
        version: query ? null : change.version,
        key: query ? null : key);
    if (!available()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    if (!query) return change.committed(raw);
    final result = change.queryResult(raw);
    if (result.current['version'] > result.committed['version'] &&
        dialog.mounted &&
        available() &&
        ModalRoute.of(dialog)?.isCurrent == true) {
      toast(dialog, '原操作已核对，设备组已有后续修改，请核对当前记录。');
    }
    return result.committed;
  }

  Future<Json?> editName(
      {Json? group, ResourceActionLease? owner, VoidCallback? onReview}) async {
    if (!current) return null;
    final before = group == null ? null : validGroup(group);
    final scope = capture();
    final id = before?['id'] as String?;
    final key = const Uuid().v4();
    var review = false;
    try {
      final result = await present<Json>(scope, (dialog, api, available) {
        Future<Json> resolve(Json values, {required bool query}) async {
          final change = before == null
              ? DeviceGroupChange.create(values)
              : DeviceGroupChange.rename(before, values);
          try {
            final result = await sendChange(dialog, api, available, change, key,
                query: query);
            review = true;
            return result;
          } catch (failure) {
            review = review || needsReview(failure);
            rethrow;
          }
        }

        return EditDialog(
            title: id == null ? '新建设备组' : '修改设备组名称',
            description: '设备组只整理本机构设备；关联设备不会自动下发或执行策略。'
                '${id == null ? '' : '\n设备组编号：$id · 原版本：${before!['version']}'}',
            fields: const [FieldSpec('name', '设备组名称')],
            initial: {'name': before?['name'] ?? ''},
            submit: id == null ? '创建设备组' : '保存名称',
            accessChanges: scope,
            hasAccess: available,
            reauth: () {
              if (available()) reauth();
            },
            recoverLabel: '查询原操作结果',
            onSubmit: (values) => resolve(values, query: false),
            onRecoverUnknown: (values) => resolve(values, query: true));
      }, owner: owner);
      if (!current || !scope.current || owner?.current == false) return null;
      if (review) onReview?.call();
      if (result == null && review) {
        if (id != null) await open(id);
      }
      return result;
    } finally {
      scope.dispose();
    }
  }

  Future<bool> create(ResourceActionLease owner) async {
    if (!current || !owner.current) return false;
    var review = false;
    final group = await editName(owner: owner, onReview: () => review = true);
    if (current && owner.current && group != null) {
      await open(group['id'] as String);
    }
    return review;
  }

  Future<void> rename() async {
    final group = detail;
    if (!current || group == null) return;
    final updated = await editName(group: group);
    if (current && updated != null) await open(updated['id'] as String);
  }

  Future<void> addDevices() async {
    if (!current || detail == null) return;
    final scope = capture(), group = Map<String, dynamic>.of(detail!);
    try {
      final chosen = await present<List<Json>>(
          scope,
          (_, api, available) => DeviceGroupBatchPicker(
              api: api, root: root, current: available, accessChanges: scope));
      if (!current || !scope.current || chosen == null || chosen.isEmpty) {
        return;
      }
      final names = chosen
          .map((row) =>
              '• ${row['displayName']}\n  设备 ${row['id']}\n  注册 ${row['registrationId']}')
          .join('\n');
      final result = await confirm(
          scope: scope,
          title: '加入设备组',
          description:
              '将以下 ${chosen.length} 台设备加入“${group['name']}”。整批会以当前组版本核对，任一设备注册周期或状态变化都不会提交。设备组关联不改变设备规则。\n\n本次设备清单：\n$names',
          submit: '确认加入 ${chosen.length} 台',
          change: DeviceGroupChange.members(
              group,
              chosen
                  .map((row) => <String, dynamic>{
                        'deviceId': row['id'],
                        'registrationId': row['registrationId']
                      })
                  .toList(),
              removing: false));
      if (current && scope.current && result != null) {
        await open(group['id'] as String);
      }
    } finally {
      scope.dispose();
    }
  }

  /// Lock before opening a child route; a retained old view cannot start work.
  Future<void> runAction(int view, Future<void> Function() operation) async {
    if (!current ||
        acting ||
        loading ||
        loadingMore ||
        showingPrevious ||
        view != generation) return;
    final action = Object(), groupId = selectedId;
    setState(() => activeAction = action);
    try {
      await operation();
    } catch (failure) {
      if (current && generation == view && selectedId == groupId) {
        setState(() => error = failure);
      }
    } finally {
      if (identical(activeAction, action)) {
        activeAction = null;
        if (mounted && _active) setState(() {});
      }
    }
  }

  Future<void> removeDevices() async {
    if (!current || detail == null) return;
    final scope = capture(), group = Map<String, dynamic>.of(detail!);
    try {
      final chosen = await present<List<Json>>(
          scope,
          (_, api, available) => DeviceGroupBatchPicker(
              api: api,
              root: root,
              groupId: group['id'] as String,
              current: available,
              accessChanges: scope));
      if (!current || !scope.current || chosen == null || chosen.isEmpty) {
        return;
      }
      final names = chosen
          .map((row) =>
              '• ${row['displayName']}\n  设备 ${row['deviceId']}\n  注册 ${row['registrationId']}')
          .join('\n');
      final result = await confirm(
          scope: scope,
          title: '批量移出设备组',
          description:
              '将以下 ${chosen.length} 台设备从“${group['name']}”移出。整批按当前组版本及原注册周期核对；不会撤销设备注册或已发布的独立配置。\n\n本次设备清单：\n$names',
          submit: '确认移出 ${chosen.length} 台',
          change: DeviceGroupChange.members(
              group,
              chosen
                  .map((row) => <String, dynamic>{
                        'deviceId': row['deviceId'],
                        'registrationId': row['registrationId']
                      })
                  .toList(),
              removing: true));
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
    try {
      final result = await confirm(
          scope: scope,
          title: '移出设备组',
          description:
              '将“${member['displayName']}”从“${group['name']}”移出。此操作不解除设备注册，也不撤销现有独立策略。\n设备 ${member['deviceId']}\n注册 ${member['registrationId']}',
          submit: '确认移出',
          change: DeviceGroupChange.members(
              group,
              [
                <String, dynamic>{
                  'deviceId': member['deviceId'],
                  'registrationId': member['registrationId']
                }
              ],
              removing: true));
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
    try {
      final result = await confirm(
          scope: scope,
          title: '归档设备组',
          description: '归档“${group['name']}”后不能继续修改成员。成员历史会保留；后续批量策略必须排除归档组。',
          submit: '确认归档',
          change: DeviceGroupChange.archive(group));
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
      required DeviceGroupChange change}) async {
    if (!current || !scope.current || selectedId == null) return null;
    final groupId = selectedId!;
    final key = const Uuid().v4();
    var review = false;
    final result = await present<Json>(scope, (dialog, api, available) {
      Future<Json> resolve({required bool query}) async {
        try {
          final result = await sendChange(dialog, api, available, change, key,
              query: query);
          review = true;
          return result;
        } catch (failure) {
          review = review || needsReview(failure);
          rethrow;
        }
      }

      return EditDialog(
          title: title,
          description: '$description\n\n设备组编号：$groupId · 原版本：${change.version}',
          fields: const [],
          initial: const {},
          submit: submit,
          accessChanges: scope,
          hasAccess: available,
          reauth: () {
            if (available()) reauth();
          },
          recoverLabel: '查询原操作结果',
          onSubmit: (_) => resolve(query: false),
          onRecoverUnknown: (_) => resolve(query: true));
    });
    if (!current || !scope.current) return null;
    if (result == null && review) await open(groupId);
    return result;
  }

  Widget healthPanel() {
    final counts = summary!;
    final view = generation;
    final total = counts.total;
    final usable = counts.current;
    Widget filterChip(String? status, String title, int count) => ChoiceChip(
          label: Text('$title $count'),
          selected: memberFilter == status,
          onSelected: acting
              ? null
              : (_) {
                  if (view == generation) chooseFilter(status);
                },
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
      final listView = generation, includeArchived = archived;
      bool sourceCurrent() =>
          current &&
          selectedId == null &&
          generation == listView &&
          archived == includeArchived;
      return ResourcePage(
          key: listKey,
          title: '机构设备组',
          subtitle: '整理设备与未来批量策略的目标范围。',
          path: '$root/device-groups?includeArchived=$archived',
          api: pageScope.api,
          isCurrent: sourceCurrent,
          onReadDenied: (failure) {
            rejectPrivateAccess(failure, sourceCurrent);
          },
          notice: '设备组只保存关联关系，不会自行限制应用、下发策略或证明系统执行。',
          emptyTitle: '暂无设备组',
          emptyDescription: '创建一个分组，再关联本机构已激活的设备。',
          createLabel: '新建设备组',
          onCreateChanged: create,
          reauth: reauth,
          toolbar: [
            FilterChip(
                label: const Text('包含已归档'),
                selected: archived,
                onSelected: (value) {
                  if (!sourceCurrent() || value == includeArchived) return;
                  setState(() {
                    generation++;
                    archived = value;
                  });
                })
          ],
          columns: [
            ColumnSpec('名称', (r) => Text('${r['name']}')),
            ColumnSpec(
                '状态', (r) => Text(r['state'] == 'ACTIVE' ? '使用中' : '已归档')),
            ColumnSpec('设备数', (r) => Text('${r['deviceCount']} 台'))
          ],
          onOpen: (row) async {
            if (!sourceCurrent() || acting) return;
            await open(row['id'] as String);
          });
    }
    final view = generation, groupId = selectedId;
    bool viewCurrent() =>
        current && generation == view && selectedId == groupId;
    void refreshDetail() {
      if (viewCurrent() && !acting && !loading && groupId != null) {
        open(groupId);
      }
    }

    final canAct = !acting && !loading && !loadingMore && !showingPrevious;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeading('设备组详情', '核对设备身份和注册周期后调整分组。',
          action: Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
                key: const Key('device-group-refresh'),
                onPressed: acting || loading ? null : refreshDetail,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新设备组')),
            OutlinedButton.icon(
                onPressed: acting
                    ? null
                    : () {
                        if (!viewCurrent() || acting) return;
                        setState(() {
                          selectedId = null;
                          detail = null;
                          summary = null;
                          memberFilter = null;
                          members = const [];
                          nextMemberCursor = null;
                          loading = loadingMore = false;
                          showingPrevious = false;
                          error = null;
                          memberPageError = null;
                          memberCursorInvalid = false;
                          generation++;
                        });
                      },
                icon: const Icon(Icons.arrow_back),
                label: const Text('返回列表'))
          ])),
      const Notice('分组成员不是策略执行回执；归档、移出设备也不会自动撤销其他独立策略。'),
      const SizedBox(height: 16),
      if (showingPrevious) ...[
        Notice(
            loading
                ? '正在刷新，显示上次读取的设备组资料；完成前暂不能修改或继续翻页。'
                : '刷新未完成，显示上次读取的设备组资料；请重试刷新后再修改或继续翻页。',
            warning: !loading),
        const SizedBox(height: 12),
      ],
      if (loading || acting) const LinearProgressIndicator(),
      if (error != null)
        Panel(
            child: FailureView(error!,
                retry: acting || loading ? null : refreshDetail,
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
                  onPressed: canAct ? () => runAction(view, addDevices) : null,
                  icon: const Icon(Icons.add),
                  label: const Text('加入设备')),
              OutlinedButton.icon(
                  onPressed:
                      canAct ? () => runAction(view, removeDevices) : null,
                  icon: const Icon(Icons.playlist_remove),
                  label: const Text('批量移出')),
              OutlinedButton.icon(
                  onPressed: canAct ? () => runAction(view, rename) : null,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('修改名称')),
              OutlinedButton.icon(
                  onPressed: canAct ? () => runAction(view, archive) : null,
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
                showingPrevious
                    ? EmptyView(
                        memberFilter == null ? '上次读取时组内暂无设备' : '上次读取时此状态下暂无设备',
                        '请刷新设备组，核对当前成员。')
                    : EmptyView(
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
                            onPressed: canAct
                                ? () =>
                                    runAction(view, () => removeDevice(member))
                                : null,
                            icon: const Icon(Icons.remove_circle_outline))
                        : null),
              if (loadingMore) const LinearProgressIndicator(),
              if (memberPageError != null) ...[
                const SizedBox(height: 12),
                Notice(
                    memberCursorInvalid
                        ? '分页信息已失效，请刷新设备组后继续。已加载记录暂时保留。'
                        : '加载更多未完成，已保留当前记录。可重试继续加载。',
                    warning: true),
                FailureView(memberPageError!, reauth: reauth),
                TextButton.icon(
                    onPressed:
                        loading || loadingMore || acting || showingPrevious
                            ? null
                            : memberCursorInvalid
                                ? refreshDetail
                                : () {
                                    if (viewCurrent() && !acting) moreMembers();
                                  },
                    icon: const Icon(Icons.refresh),
                    label: Text(memberCursorInvalid ? '刷新设备组' : '重试加载更多')),
              ],
              if (memberPageError == null && nextMemberCursor != null)
                TextButton.icon(
                    onPressed:
                        loading || loadingMore || acting || showingPrevious
                            ? null
                            : () {
                                if (viewCurrent() && !acting) moreMembers();
                              },
                    icon: const Icon(Icons.expand_more),
                    label: const Text('加载更多设备'))
            ]))
      ]
    ]);
  }
}

/// Preserve the original API's transport, deadlines, paging and pending writes.
/// A borrowed child view reports rejection only while all its guards still hold.
class _GroupDialogApi extends Api {
  final Api source;
  final void Function(Object) rejected;
  _GroupDialogApi(this.source, this.rejected)
      : super(source.client, baseUrl: source.baseUrl);

  Future<T> request<T>(
      bool Function()? isCurrent, Future<T> Function() operation) async {
    try {
      return await operation();
    } catch (failure) {
      if (isCurrent?.call() != false) rejected(failure);
      rethrow;
    }
  }

  @override
  Api trackingWrites(ApiWriteDispatch observation) =>
      _GroupDialogApi(source.trackingWrites(observation), rejected);

  @override
  Api scoped(bool Function() isCurrent) =>
      _GroupDialogApi(source.scoped(isCurrent), (failure) {
        if (isCurrent()) rejected(failure);
      });

  @override
  Future<dynamic> send(String method, String path,
          {Json? body,
          int? version,
          String? key,
          String? clientRequestId,
          bool Function()? isCurrent}) =>
      request(
          isCurrent,
          () => source.send(method, path,
              body: body,
              version: version,
              key: key,
              clientRequestId: clientRequestId,
              isCurrent: isCurrent));

  @override
  Future<PageResult> page(String path,
          {String? cursor, bool Function()? isCurrent}) =>
      request(isCurrent,
          () => source.page(path, cursor: cursor, isCurrent: isCurrent));

  @override
  Future<List<Json>> all(String path, {bool Function()? isCurrent}) =>
      request(isCurrent, () => source.all(path, isCurrent: isCurrent));
}

/// All selectors hide their private contents before a revoked route is removed.
class _GroupScopeView extends StatefulWidget {
  final DeviceSubflowScope scope;
  final Listenable changes;
  final WidgetBuilder builder;
  final bool Function() hasAccess;
  const _GroupScopeView(
      {required this.scope,
      required this.changes,
      required this.builder,
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
    widget.changes.addListener(changed);
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
    widget.changes.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => permitted
      ? widget.builder(context)
      : AlertDialog(
          title: const Text('工作空间或权限已变化'),
          content: const Text('已隐藏原操作内容。请关闭窗口，在当前工作空间重新打开。'),
          actions: [
              TextButton(
                  onPressed: () {
                    final route = _route;
                    if (!mounted || !_active || route?.isCurrent != true) {
                      return;
                    }
                    if (route is OwnedDialogRoute<dynamic>) route.finish();
                  },
                  child: const Text('关闭'))
            ]);
}
