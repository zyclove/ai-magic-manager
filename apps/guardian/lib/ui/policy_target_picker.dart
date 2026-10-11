import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/device_group_summary.dart';
import '../core/session.dart';
import 'design.dart';

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

class PolicyTargetPicker extends StatefulWidget {
  final Session session;
  final String root, actor, role;
  const PolicyTargetPicker(
      {super.key,
      required this.session,
      required this.root,
      required this.actor,
      required this.role});

  @override
  State<PolicyTargetPicker> createState() => _PolicyTargetPickerState();
}

class _PolicyTargetPickerState extends State<PolicyTargetPicker> {
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
      widget.session.authenticated &&
      widget.session.tenant != null &&
      widget.session.root == widget.root &&
      widget.session.profile?['subject'] == widget.actor &&
      widget.session.role == widget.role &&
      widget.session.canOpen('policies');
  bool get canUseGroups => widget.session.canOpen('device-groups');

  @override
  void initState() {
    super.initState();
    widget.session.addListener(accessChanged);
    loadDevices();
    if (canUseGroups) loadGroups();
  }

  void accessChanged() {
    if (!current) {
      generation++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      });
    }
  }

  @override
  void dispose() {
    generation++;
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
      final page = await widget.session.api
          .page('${widget.root}/devices', cursor: cursor);
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
      if (current && revision == generation) {
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
      final page = await widget.session.api
          .page('${widget.root}/device-groups', cursor: cursor);
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
      if (current && revision == generation) {
        setState(() => groupError = failure);
      }
    } finally {
      if (current && revision == generation) {
        setState(() => loadingGroups = false);
      }
    }
  }

  Future<void> chooseGroup(String id) async {
    if (!current || !canUseGroups || loadingGroup) return;
    final revision = generation;
    setState(() {
      loadingGroup = true;
      groupError = null;
      requestedGroupId = id;
      selected.clear();
      groupRegistrations.clear();
      groupId = null;
      groupName = null;
      groupVersion = null;
      excludedGroupDevices = 0;
    });
    try {
      final group = await widget.session.api
          .send('GET', '${widget.root}/device-groups/$id');
      if (!current || revision != generation) return;
      if (group is! Json ||
          group['id'] != id ||
          group['state'] != 'ACTIVE' ||
          group['version'] is! int ||
          group['name'] is! String) {
        throw const ApiFailure(409, 'POLICY_GROUP_SELECTION_UNAVAILABLE');
      }
      final health = DeviceGroupSummary.read(
          await widget.session.api
              .send('GET', '${widget.root}/device-groups/$id/summary'),
          group);
      if (!current || revision != generation) return;
      if (health.current == 0) {
        throw const ApiFailure(409, 'POLICY_GROUP_SELECTION_UNAVAILABLE');
      }
      if (health.current > 50) {
        throw const ApiFailure(409, 'POLICY_GROUP_TOO_MANY_ELIGIBLE_DEVICES');
      }
      final page = await widget.session.api
          .page('${widget.root}/device-groups/$id/devices?status=CURRENT');
      if (!current || revision != generation) return;
      final latest = await widget.session.api
          .send('GET', '${widget.root}/device-groups/$id');
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
        selected
          ..clear()
          ..addAll(page.items.map((row) => row['deviceId'] as String));
        for (final row in page.items) {
          names[row['deviceId'] as String] = row['displayName'] as String;
          groupRegistrations[row['deviceId'] as String] =
              row['registrationId'] as String;
        }
        groupId = id;
        groupName = group['name'] as String;
        groupVersion = group['version'] as int;
        excludedGroupDevices = health.excluded;
      });
    } catch (failure) {
      if (current && revision == generation) {
        setState(() => groupError = failure);
      }
    } finally {
      if (current && revision == generation) {
        setState(() => loadingGroup = false);
      }
    }
  }

  void toggle(Json row, bool checked) {
    if (!current || row['state'] != 'ACTIVE') return;
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
    });
  }

  void finish() {
    if (!current || selected.isEmpty || selected.length > 50) return;
    Navigator.pop(
        context,
        PolicyTargetSelection(selected.toList()..sort(), names,
            groupId: groupId,
            groupVersion: groupVersion,
            groupName: groupName,
            groupRegistrations: groupRegistrations));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('选择策略预览目标'),
          content: SizedBox(
              width: 700,
              height: 600,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Notice(
                        '此处只选择本次预览的明确设备快照，最多 50 台。设备组以后增减成员不会自动改变已发布配置。'),
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
                                    labelText: '从设备组选择（可选）'),
                                items: groups
                                    .map((group) => DropdownMenuItem<String>(
                                        value: group['id'] as String,
                                        child: Text(
                                            '${group['name']} · ${group['deviceCount']} 台',
                                            overflow: TextOverflow.ellipsis)))
                                    .toList(),
                                onChanged: loadingGroup || loadingGroups
                                    ? null
                                    : (id) {
                                        if (id != null) chooseGroup(id);
                                      })),
                        if (groupCursor != null)
                          TextButton(
                              onPressed: loadingGroups
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
                            reauth: () => widget.session.login(stepUp: true)),
                    ],
                    const SizedBox(height: 10),
                    Text(
                        '已选 ${selected.length} / 50 台${groupName == null ? '' : ' · 来自“$groupName”第 $groupVersion 版'}'),
                    if (groupId != null)
                      Text(
                          '选择来自当前设备组快照；发布前会再次核对组版本。${excludedGroupDevices > 0 ? '$excludedGroupDevices 台非活动或关联失效设备已排除。' : ''}',
                          style: const TextStyle(color: muted)),
                    if (selected.isNotEmpty)
                      Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                              onPressed: () => setState(() {
                                    selected.clear();
                                    groupRegistrations.clear();
                                    groupId = null;
                                    groupName = null;
                                    groupVersion = null;
                                    excludedGroupDevices = 0;
                                  }),
                              child: const Text('清空选择'))),
                    const SizedBox(height: 8),
                    Expanded(
                        child: ListView(children: [
                      if (devices.isEmpty && !loadingDevices)
                        const EmptyView('尚无可选择设备', '请先在设备管理中完成激活，或检查当前列表。'),
                      for (final row in devices)
                        CheckboxListTile(
                            value: selected.contains(row['id']),
                            onChanged: row['state'] != 'ACTIVE' ||
                                    loadingGroup ||
                                    selected.length >= 50 &&
                                        !selected.contains(row['id'])
                                ? null
                                : (checked) => toggle(row, checked == true),
                            title: Text('${row['displayName']}'),
                            subtitle: Text(
                                '${row['platform']} · ${row['state']} · ${row['id']}'),
                            controlAffinity: ListTileControlAffinity.leading),
                      if (loadingDevices) const LinearProgressIndicator(),
                      if (deviceError != null)
                        FailureView(deviceError!,
                            retry: () =>
                                loadDevices(more: deviceCursor != null),
                            reauth: () => widget.session.login(stepUp: true)),
                      if (deviceCursor != null)
                        TextButton.icon(
                            onPressed: loadingDevices
                                ? null
                                : () => loadDevices(more: true),
                            icon: const Icon(Icons.expand_more),
                            label: const Text('加载更多设备'))
                    ]))
                  ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: current && selected.isNotEmpty && !loadingGroup
                    ? finish
                    : null,
                child: const Text('预览这些设备'))
          ]);
}
