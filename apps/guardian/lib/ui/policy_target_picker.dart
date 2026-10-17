import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/device_group_summary.dart';
import '../core/session.dart';
import '../core/labels.dart';
import 'design.dart';
import 'owned_dialog_route.dart';

typedef PolicyTargetPreview = Future<void> Function(
    PolicyTargetSelection selection, bool Function() isCurrent);

/// A one-time explicit device selection for the existing policy preview API.
/// Group membership never becomes a hidden dynamic policy target here.
class PolicyTargetSelection {
  final List<String> deviceIds;
  final Map<String, String> names;
  final Map<String, String> groupRegistrations;
  final String? groupId;
  final int? groupVersion;
  final String? groupName;
  PolicyTargetSelection(Iterable<String> deviceIds, Map<String, String> names,
      {this.groupId,
      this.groupVersion,
      this.groupName,
      Map<String, String> groupRegistrations = const {}})
      : deviceIds = List.unmodifiable(deviceIds),
        names = Map.unmodifiable(names),
        groupRegistrations = Map.unmodifiable(groupRegistrations);
}

/// Opens one owned picker route and waits for its result and removal.
Future<PolicyTargetSelection?> showPolicyTargetPicker({
  required BuildContext context,
  required Session session,
  required String root,
  required String actor,
  required String role,
  PolicyTargetPreview? onPreview,
}) {
  final scopeGeneration = session.scopeGeneration;
  final route = OwnedDialogRoute<PolicyTargetSelection>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PolicyTargetPicker(
      session: session,
      root: root,
      actor: actor,
      role: role,
      onPreview: onPreview,
      expectedScopeGeneration: scopeGeneration,
    ),
  );
  return presentOwnedDialog(context, route);
}

class PolicyTargetPicker extends StatefulWidget {
  final Session session;
  final String root, actor, role;
  final PolicyTargetPreview? onPreview;
  final int? expectedScopeGeneration;
  const PolicyTargetPicker(
      {super.key,
      required this.session,
      required this.root,
      required this.actor,
      required this.role,
      this.onPreview,
      this.expectedScopeGeneration});

  @override
  State<PolicyTargetPicker> createState() => _PolicyTargetPickerState();
}

class _PolicyTargetPickerState extends State<PolicyTargetPicker> {
  final searchController = TextEditingController();
  final scrollController = ScrollController();
  String search = '';
  bool onlySelected = false;
  bool closing = false;
  bool previewing = false;
  Object? previewError;
  late final int scopeGeneration;
  late final Api api;
  final devices = <Json>[];
  final groups = <Json>[];
  final selected = <String>{};
  final names = <String, String>{};
  final groupRegistrations = <String, String>{};
  String? deviceCursor, groupCursor, groupId, groupName, requestedGroupId;
  int? groupVersion;
  int excludedGroupDevices = 0;
  bool loadingDevices = false, loadingGroups = false, loadingGroup = false;
  Object? deviceError, groupError;
  int generation = 0;

  bool get current =>
      mounted &&
      !closing &&
      widget.session.scopeGeneration == scopeGeneration &&
      widget.session.authenticated &&
      widget.session.tenant != null &&
      widget.session.root == widget.root &&
      widget.session.profile?['subject'] == widget.actor &&
      widget.session.role == widget.role &&
      widget.session.canOpen('policies');
  void reauthenticate() {
    if (!current ||
        previewing ||
        loadingDevices ||
        loadingGroups ||
        loadingGroup ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    widget.session.login(stepUp: true);
  }

  bool get canUseGroups => widget.session.canOpen('device-groups');

  @override
  void initState() {
    super.initState();
    scopeGeneration =
        widget.expectedScopeGeneration ?? widget.session.scopeGeneration;
    api = widget.session.api.scoped(() => current);
    widget.session.addListener(accessChanged);
    loadDevices();
    if (canUseGroups) loadGroups();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A workspace change can precede the first frame and listener registration.
    // Route dependencies are available here, including on the initial build.
    accessChanged();
  }

  void accessChanged() {
    if (!mounted || closing || current) return;
    invalidate();
  }

  bool privateFailure(Object failure) {
    if (failure is ApiFailure &&
        (failure.code == 'WORKSPACE_CHANGED' ||
            failure.status == 403 ||
            (failure.status == 401 && failure.code != 'REAUTH_REQUIRED'))) {
      invalidate();
      return true;
    }
    return false;
  }

  bool routeAvailable(ModalRoute<dynamic>? route) =>
      route is OwnedDialogRoute<PolicyTargetSelection>
          ? route.available
          : route?.isActive == true && route?.navigator != null;

  void finishRoute(ModalRoute<dynamic>? route,
      [PolicyTargetSelection? selection]) {
    if (!routeAvailable(route)) return;
    if (route is OwnedDialogRoute<PolicyTargetSelection>) {
      route.finish(selection);
      return;
    }
    final navigator = route!.navigator!;
    if (route.isCurrent) {
      navigator.pop(selection);
    } else {
      navigator.removeRoute(route);
    }
  }

  void invalidate() {
    if (!mounted || closing) return;
    // Latch before scheduling: repeated session events must not close a parent
    // page while this dialog is still mounted during its exit animation.
    setState(() {
      closing = true;
      generation++;
      devices.clear();
      groups.clear();
      selected.clear();
      names.clear();
      groupRegistrations.clear();
      deviceCursor =
          groupCursor = groupId = groupName = requestedGroupId = null;
      groupVersion = null;
      excludedGroupDevices = 0;
      onlySelected = false;
      search = '';
      searchController.clear();
      deviceError = groupError = previewError = null;
      loadingDevices = loadingGroups = loadingGroup = previewing = false;
    });
    final route = ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) finishRoute(route);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    generation++;
    searchController.dispose();
    scrollController.dispose();
    widget.session.removeListener(accessChanged);
    super.dispose();
  }

  Future<void> loadDevices({bool more = false}) async {
    if (!current || loadingDevices || (more && deviceCursor == null)) return;
    final revision = generation;
    final cursor = more ? deviceCursor : null;
    setState(() {
      loadingDevices = true;
      deviceError = null;
    });
    try {
      final page = await api.page('${widget.root}/devices', cursor: cursor);
      if (!current || revision != generation) return;
      if (page.items.any((row) =>
          row['id'] is! String ||
          row['displayName'] is! String ||
          row['state'] is! String ||
          (more && devices.any((old) => old['id'] == row['id'])))) {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
      setState(() {
        if (!more) devices.clear();
        devices.addAll(page.items);
        for (final row in page.items) {
          names[row['id'] as String] = row['displayName'] as String;
        }
        deviceCursor = page.nextCursor;
      });
    } catch (failure) {
      if (current && revision == generation && !privateFailure(failure)) {
        setState(() => deviceError = failure);
      }
    } finally {
      if (current && revision == generation) {
        setState(() => loadingDevices = false);
      }
    }
  }

  Future<void> loadGroups({bool more = false}) async {
    if (!current ||
        !canUseGroups ||
        loadingGroups ||
        (more && groupCursor == null)) return;
    final revision = generation;
    final cursor = more ? groupCursor : null;
    setState(() {
      loadingGroups = true;
      groupError = null;
    });
    try {
      final page =
          await api.page('${widget.root}/device-groups', cursor: cursor);
      if (!current || revision != generation) return;
      if (page.items.any((row) =>
          row['id'] is! String ||
          row['name'] is! String ||
          row['state'] != 'ACTIVE' ||
          row['version'] is! int ||
          (more && groups.any((old) => old['id'] == row['id'])))) {
        throw const ApiFailure(502, 'INVALID_DEVICE_GROUP_RESPONSE');
      }
      setState(() {
        if (!more) groups.clear();
        groups.addAll(page.items);
        groupCursor = page.nextCursor;
      });
    } catch (failure) {
      if (current && revision == generation && !privateFailure(failure)) {
        setState(() => groupError = failure);
      }
    } finally {
      if (current && revision == generation) {
        setState(() => loadingGroups = false);
      }
    }
  }

  Future<void> chooseGroup(String id) async {
    if (!current || !canUseGroups || loadingGroup || previewing) return;
    final revision = generation;
    setState(() {
      loadingGroup = true;
      groupError = null;
      requestedGroupId = id;
    });
    try {
      final group = await api.send('GET', '${widget.root}/device-groups/$id');
      if (!current || revision != generation) return;
      if (group is! Json ||
          group['id'] != id ||
          group['state'] != 'ACTIVE' ||
          group['version'] is! int ||
          group['name'] is! String) {
        throw const ApiFailure(409, 'POLICY_GROUP_SELECTION_UNAVAILABLE');
      }
      final health = DeviceGroupSummary.read(
          await api.send('GET', '${widget.root}/device-groups/$id/summary'),
          group);
      if (!current || revision != generation) return;
      if (health.current == 0) {
        throw const ApiFailure(409, 'POLICY_GROUP_SELECTION_UNAVAILABLE');
      }
      if (health.current > 50) {
        throw const ApiFailure(409, 'POLICY_GROUP_TOO_MANY_ELIGIBLE_DEVICES');
      }
      final page = await api
          .page('${widget.root}/device-groups/$id/devices?status=CURRENT');
      if (!current || revision != generation) return;
      final latest = await api.send('GET', '${widget.root}/device-groups/$id');
      if (!current || revision != generation) return;
      if (latest is! Json ||
          latest['id'] != id ||
          latest['state'] != 'ACTIVE' ||
          latest['version'] != group['version'] ||
          latest['deviceCount'] != health.total ||
          page.nextCursor != null ||
          page.items.length != health.current ||
          page.items.map((row) => row['deviceId']).toSet().length !=
              health.current ||
          page.items.any((row) =>
              row['deviceId'] is! String ||
              row['registrationId'] is! String ||
              row['displayName'] is! String ||
              row['state'] != 'ACTIVE' ||
              row['membershipStatus'] != 'CURRENT')) {
        throw const ApiFailure(409, 'POLICY_GROUP_SELECTION_UNAVAILABLE');
      }
      setState(() {
        // Replace only after the entire group snapshot has been validated.
        // A failed request must not discard the administrator's existing work.
        selected
          ..clear()
          ..addAll(page.items.map((row) => row['deviceId'] as String));
        groupRegistrations.clear();
        for (final row in page.items) {
          names[row['deviceId'] as String] = row['displayName'] as String;
          groupRegistrations[row['deviceId'] as String] =
              row['registrationId'] as String;
        }
        groupId = id;
        groupName = group['name'] as String;
        groupVersion = group['version'] as int;
        excludedGroupDevices = health.excluded;
        onlySelected = true;
        searchController.clear();
        search = '';
        previewError = null;
      });
    } catch (failure) {
      if (current && revision == generation && !privateFailure(failure)) {
        setState(() => groupError = failure);
      }
    } finally {
      if (current && revision == generation) {
        setState(() => loadingGroup = false);
      }
    }
  }

  void toggle(Json row, bool checked) {
    if (!current || loadingGroup || previewing || row['state'] != 'ACTIVE') {
      return;
    }
    final id = row['id'] as String;
    if (checked && selected.length >= 50 && !selected.contains(id)) return;
    setState(() {
      if (checked) {
        selected.add(id);
      } else {
        selected.remove(id);
      }
      groupId = null;
      groupRegistrations.clear();
      groupName = null;
      groupVersion = null;
      excludedGroupDevices = 0;
      previewError = null;
    });
  }

  Future<void> finish() async {
    if (!current ||
        loadingGroup ||
        previewing ||
        selected.isEmpty ||
        selected.length > 50) {
      return;
    }
    final route = ModalRoute.of(context);
    final revision = generation;
    final selection = PolicyTargetSelection(selected.toList()..sort(), names,
        groupId: groupId,
        groupVersion: groupVersion,
        groupName: groupName,
        groupRegistrations: groupRegistrations);
    FocusScope.of(context).unfocus();
    setState(() {
      previewing = true;
      previewError = null;
    });
    try {
      await widget.onPreview?.call(selection,
          () => current && revision == generation && routeAvailable(route));
      if (!current || revision != generation || !routeAvailable(route)) return;
      closing = true;
      generation++;
      finishRoute(route, selection);
    } catch (failure) {
      if (!current || revision != generation) return;
      if (privateFailure(failure)) return;
      setState(() => previewError = failure);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (current && scrollController.hasClients) scrollController.jumpTo(0);
      });
    } finally {
      if (current && revision == generation) setState(() => previewing = false);
    }
  }

  bool matches(String id, String name) =>
      '$name $id'.toLowerCase().contains(search);

  void cancel() {
    if (!mounted || closing) return;
    final route = ModalRoute.of(context);
    closing = true;
    generation++;
    finishRoute(route);
  }

  // Reviewing a group must include members outside the loaded device page.
  // Removing a member switches to explicit device selection, just as toggle.
  void removeSelection(String id) {
    if (!current || loadingGroup || previewing) return;
    setState(() {
      selected.remove(id);
      groupRegistrations.clear();
      groupId = null;
      groupName = null;
      groupVersion = null;
      excludedGroupDevices = 0;
      previewError = null;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
      onPopInvoked: (didPop) {
        if (!didPop || closing) return;
        closing = true;
        generation++;
      },
      child: AlertDialog(
          title: const Text('选择策略预览目标'),
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          content: SizedBox(
              width: 700,
              height: 600,
              child: ListView(controller: scrollController, children: [
                const Text('选择设备，再预览规则对这些设备的影响。'),
                if (previewing) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                  Semantics(
                      liveRegion: true, child: const Text('正在核对目标和规则，请稍候。')),
                ],
                if (previewError != null) ...[
                  FailureView(previewError!, reauth: reauthenticate),
                  const Text('已保留设备选择。可调整目标，或点击“重试预览”。'),
                ],
                const SizedBox(height: 12),
                TextField(
                    enabled: !previewing,
                    controller: searchController,
                    decoration: InputDecoration(
                        labelText: '搜索设备名称或编号',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: searchController.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清除搜索',
                                onPressed: () => setState(() {
                                      searchController.clear();
                                      search = '';
                                    }),
                                icon: const Icon(Icons.close))),
                    onChanged: (value) =>
                        setState(() => search = value.trim().toLowerCase())),
                const SizedBox(height: 8),
                Text(
                    onlySelected
                        ? '正在核对已选设备，搜索不会取消选择。'
                        : deviceCursor != null
                            ? '仅搜索已加载设备；可在下方加载更多。'
                            : '搜索当前已加载设备，搜索不会取消选择。',
                    style: const TextStyle(color: muted)),
                Align(
                    alignment: Alignment.centerLeft,
                    child: FilterChip(
                        label: const Text('只看已选'),
                        selected: onlySelected,
                        onSelected: loadingGroup || previewing
                            ? null
                            : (value) => setState(() => onlySelected = value))),
                if (canUseGroups) ...[
                  const SizedBox(height: 14),
                  Row(children: [
                    Expanded(
                        child: DropdownButtonFormField<String>(
                            isExpanded: true,
                            value: groupId != null &&
                                    groups.any((g) => g['id'] == groupId)
                                ? groupId
                                : null,
                            decoration: const InputDecoration(
                                labelText: '用设备组替换选择（可选）'),
                            items: groups
                                .map((group) => DropdownMenuItem<String>(
                                    value: group['id'] as String,
                                    child: Text(
                                        '${group['name']} · ${group['deviceCount']} 台',
                                        overflow: TextOverflow.ellipsis)))
                                .toList(),
                            onChanged:
                                loadingGroup || loadingGroups || previewing
                                    ? null
                                    : (id) {
                                        if (id != null) chooseGroup(id);
                                      })),
                    if (groupCursor != null)
                      TextButton(
                          onPressed: loadingGroups || previewing
                              ? null
                              : () => loadGroups(more: true),
                          child: const Text('更多组'))
                  ]),
                  if (loadingGroup || loadingGroups)
                    const LinearProgressIndicator(),
                  if (groupError != null)
                    FailureView(groupError!,
                        retry: groupError is ApiFailure &&
                                const {
                                  'POLICY_GROUP_SELECTION_UNAVAILABLE',
                                  'POLICY_GROUP_TOO_MANY_ELIGIBLE_DEVICES'
                                }.contains((groupError as ApiFailure).code)
                            ? null
                            : () => requestedGroupId == null
                                ? loadGroups()
                                : chooseGroup(requestedGroupId!),
                        reauth: reauthenticate),
                ],
                const SizedBox(height: 10),
                Semantics(
                    liveRegion: true,
                    child: Text('已选 ${selected.length} / 50 台',
                        style: Theme.of(context).textTheme.titleMedium)),
                if (groupId != null) Text('来自“$groupName”第 $groupVersion 版'),
                if (selected.length >= 50)
                  const Notice('已达到 50 台上限。请先移除设备，再添加其他设备。'),
                if (groupId != null)
                  Text(
                      '选择来自当前设备组快照；发布前会再次核对组版本。${excludedGroupDevices > 0 ? '$excludedGroupDevices 台非活动或关联失效设备已排除。' : ''}',
                      style: const TextStyle(color: muted)),
                if (selected.isNotEmpty)
                  Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                          onPressed: loadingGroup || previewing || !current
                              ? null
                              : () => setState(() {
                                    selected.clear();
                                    groupRegistrations.clear();
                                    groupId = null;
                                    groupName = null;
                                    groupVersion = null;
                                    excludedGroupDevices = 0;
                                    previewError = null;
                                  }),
                          child: const Text('清空选择'))),
                const SizedBox(height: 8),
                if (onlySelected) ...[
                  if (!selected.any((id) => matches(id, names[id] ?? id)))
                    EmptyView(
                        selected.isEmpty ? '尚未选择设备' : '没有匹配的设备',
                        selected.isEmpty
                            ? '关闭“只看已选”，选择设备或设备组。'
                            : '清除搜索可查看全部已选设备。'),
                  for (final id
                      in selected.where((id) => matches(id, names[id] ?? id)))
                    CheckboxListTile(
                        key: ValueKey('selected-$id'),
                        value: true,
                        onChanged: loadingGroup || previewing
                            ? null
                            : (_) => removeSelection(id),
                        title: Text(names[id] ?? id),
                        subtitle: Text('已选择 · $id'),
                        controlAffinity: ListTileControlAffinity.leading),
                ] else ...[
                  if (devices.isEmpty && !loadingDevices && deviceError == null)
                    const EmptyView('尚无可选择设备', '请先在设备管理中完成激活，或检查当前列表。'),
                  if (devices.isNotEmpty &&
                      !devices.any((row) => matches(
                          row['id'] as String, row['displayName'] as String)))
                    const EmptyView('没有匹配的设备', '请尝试其他名称或编号；已有选择仍保留。'),
                  for (final row in devices.where((row) => matches(
                      row['id'] as String, row['displayName'] as String)))
                    CheckboxListTile(
                        key: ValueKey(row['id']),
                        value: selected.contains(row['id']),
                        onChanged: row['state'] != 'ACTIVE' ||
                                loadingGroup ||
                                previewing ||
                                selected.length >= 50 &&
                                    !selected.contains(row['id'])
                            ? null
                            : (checked) => toggle(row, checked == true),
                        title: Text('${row['displayName']}'),
                        subtitle: Text(
                            '${label(row['platform'])} · ${label(row['state'])}'
                            '${row['state'] == 'ACTIVE' ? '' : ' · 当前不可选择'}\n${row['id']}'),
                        controlAffinity: ListTileControlAffinity.leading),
                ],
                if (loadingDevices) const LinearProgressIndicator(),
                if (deviceError != null)
                  FailureView(deviceError!,
                      retry: () => loadDevices(more: deviceCursor != null),
                      reauth: reauthenticate),
                if (deviceCursor != null && !onlySelected)
                  TextButton.icon(
                      onPressed: loadingDevices || previewing
                          ? null
                          : () => loadDevices(more: true),
                      icon: const Icon(Icons.expand_more),
                      label: const Text('加载更多设备')),
                const ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text('选择与发布说明'),
                    children: [
                      Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: Text(
                              '本次只选择明确的设备列表，最多 50 台。设备组以后增减成员不会自动改变已发布配置。预览后还需要明确发布，实际生效情况以设备回执为准。'))
                    ]),
              ])),
          actions: [
            TextButton(onPressed: cancel, child: const Text('取消')),
            FilledButton(
                onPressed: current &&
                        selected.isNotEmpty &&
                        !loadingGroup &&
                        !previewing
                    ? finish
                    : null,
                child: Text(previewing
                    ? '正在预览…'
                    : previewError == null
                        ? '预览这些设备'
                        : '重试预览'))
          ]));
}
