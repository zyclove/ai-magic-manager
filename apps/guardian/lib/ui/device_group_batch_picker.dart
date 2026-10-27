import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/api.dart';
import '../core/labels.dart';
import 'design.dart';
import 'owned_dialog_route.dart';

/// Explicit device registration selection for one atomic group-membership request.
class DeviceGroupBatchPicker extends StatefulWidget {
  final Api api;
  final String root;
  final String? groupId;
  final bool Function() current;
  final Listenable? accessChanges;

  const DeviceGroupBatchPicker(
      {super.key,
      required this.api,
      required this.root,
      this.groupId,
      required this.current,
      this.accessChanges});

  @override
  State<DeviceGroupBatchPicker> createState() => _DeviceGroupBatchPickerState();
}

class _DeviceGroupBatchPickerState extends State<DeviceGroupBatchPicker> {
  final selected = <String, Json>{};
  final searchController = TextEditingController();
  final searchFocus = FocusNode(debugLabel: 'device-group-batch-search');
  String search = '';
  bool onlySelected = false;
  List<Json> devices = const [];
  String? cursor;
  Object? error;
  bool loading = false, cursorInvalid = false;
  ModalRoute<dynamic>? _route;
  bool _active = true, _revoked = false, _rebuildPending = false;
  int generation = 0;

  void _observeAccess() {
    if (!_revoked && !widget.current()) _revoked = true;
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
    generation++;
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

  void finish([List<Json>? result]) {
    if (!mounted || !_active) return;
    final route = _route;
    if (route is OwnedDialogRoute<List<Json>>) {
      route.finish(result);
    } else if (route?.isCurrent == true) {
      route!.navigator?.pop(result);
    }
  }

  void close() {
    if (current) finish();
  }

  void confirm() {
    if (!current || selected.isEmpty || selected.length > 50 ||
        selected.entries.any((entry) => entry.key != idOf(entry.value) ||
            !selectable(entry.value))) return;
    finish(List<Json>.unmodifiable(selected.values));
  }

  bool selectable(Json row) => devices.any((item) =>
      idOf(item) == idOf(row) &&
      item['registrationId'] == row['registrationId'] &&
      (removing || item['state'] == 'ACTIVE'));

  List<Json> get visibleDevices => devices.where((row) =>
      (!onlySelected || selected.containsKey(idOf(row))) &&
      '${row['displayName']} ${idOf(row)} ${row['registrationId']}'
          .toLowerCase().contains(search)).toList();

  void changeSearch(String value) {
    if (!current) return;
    setState(() => search = value.trim().toLowerCase());
  }

  void clearSearch() {
    if (!current) return;
    searchController.clear();
    setState(() => search = '');
    searchFocus.requestFocus();
  }

  void changeSelectedFilter(bool value) {
    if (!current) return;
    setState(() => onlySelected = value);
  }

  void clearSelection() {
    if (!current) return;
    setState(selected.clear);
  }
  bool get removing => widget.groupId != null;
  String idOf(Json row) => row[removing ? 'deviceId' : 'id'] as String;

  @override
  void initState() {
    super.initState();
    _observeAccess();
    widget.accessChanges?.addListener(_accessChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ModalRoute.of(context);
    if (_route != null && !identical(_route, next)) _revoked = true;
    _route = next;
  }

  @override
  void didUpdateWidget(DeviceGroupBatchPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.accessChanges, widget.accessChanges)) {
      oldWidget.accessChanges?.removeListener(_accessChanged);
      widget.accessChanges?.addListener(_accessChanged);
    }
    if (oldWidget.root != widget.root || oldWidget.groupId != widget.groupId ||
        !identical(oldWidget.api, widget.api)) _revoked = true;
    _observeAccess();
  }

  @override
  void deactivate() {
    _active = false;
    _revoked = true;
    generation++;
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
    generation++;
    widget.accessChanges?.removeListener(_accessChanged);
    searchController.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    if (!current || loading || cursorInvalid || (more && cursor == null)) {
      return;
    }
    final requestedCursor = more ? cursor : null;
    final requested = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final path = removing
          ? '${widget.root}/device-groups/${widget.groupId}/devices'
          : '${widget.root}/devices';
      final page = await widget.api.page(path, cursor: requestedCursor,
          isCurrent: () => mounted && _active && permitted &&
              generation == requested);
      if (!mounted || !_active || !permitted || generation != requested) return;
      final seen = more ? devices.map(idOf).toSet() : <String>{};
      for (final row in page.items) {
        if (row[removing ? 'deviceId' : 'id'] is! String ||
            row['registrationId'] is! String ||
            row['displayName'] is! String ||
            row['state'] is! String ||
            row['platform'] is! String ||
            (removing && row['membershipStatus'] is! String) ||
            !seen.add(idOf(row))) {
          throw const ApiFailure(502, 'INVALID_DEVICE_GROUP_RESPONSE');
        }
      }
      setState(() {
        devices =
            List.unmodifiable(more ? [...devices, ...page.items] : page.items);
        cursor = page.nextCursor;
      });
    } catch (failure) {
      if (mounted && _active && permitted && generation == requested) {
        setState(() {
          if (failure is ApiFailure &&
              (failure.code == 'WORKSPACE_CHANGED' ||
                  failure.status == 403 ||
                  (failure.status == 401 && failure.code != 'REAUTH_REQUIRED'))) {
            _revoked = true;
            generation++;
            selected.clear();
            devices = const [];
            search = '';
            searchController.clear();
            onlySelected = false;
            cursor = null;
            cursorInvalid = false;
            loading = false;
            error = null;
          } else {
            error = failure;
            if (more && failure is ApiFailure && failure.code == 'INVALID_CURSOR') {
              cursor = null;
              cursorInvalid = true;
            }
          }
        });
      }
    } finally {
      if (mounted && _active && permitted && generation == requested) {
        setState(() => loading = false);
      }
    }
  }

  void reloadFromStart() {
    if (!current || loading || !cursorInvalid) return;
    setState(() {
      selected.clear();
      devices = const [];
      cursor = null;
      error = null;
      cursorInvalid = false;
      onlySelected = false;
    });
    load();
  }

  void toggle(Json row) {
    if (!current || (!removing && row['state'] != 'ACTIVE')) return;
    final id = idOf(row);
    if (!selectable(row)) return;
    setState(() {
      if (selected.containsKey(id)) {
        selected.remove(id);
      } else if (selected.length < 50) {
        selected[id] = row;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!permitted) {
      return AlertDialog(
          title: const Text('工作空间或权限已变化'),
          content: const Text('已隐藏原设备选择。请关闭窗口，在当前工作空间重新打开。'),
          actions: [TextButton(onPressed: () {
            if (_route?.isCurrent == true) finish();
          }, child: const Text('关闭'))]);
    }
    final visible = visibleDevices;
    return AlertDialog(
        title: Text(removing ? '批量移出设备组' : '选择加入设备'),
        scrollable: true,
        content: SizedBox(
            width: 600,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(removing
                      ? '可清理停用、旧注册周期及其他成员；单次最多 50 台。移出不撤销设备注册或已有独立策略。'
                      : '可选择 1～50 台已激活的本机构设备。确认时会重新核对每台设备的注册周期。'),
                  const SizedBox(height: 12),
                  TextField(
                      controller: searchController,
                      focusNode: searchFocus,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                          labelText: '搜索已加载设备',
                          helperText: '按名称、设备编号或注册编号查找；不会自动查询未加载的设备。',
                          helperMaxLines: 3,
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: searchController.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '清除设备搜索',
                                  onPressed: clearSearch,
                                  icon: const Icon(Icons.close))),
                      onChanged: changeSearch),
                  const SizedBox(height: 12),
                  Semantics(
                      liveRegion: true,
                      child: Text('已选择 ${selected.length} / 50 台 · 当前显示 ${visible.length} 台',
                          style: Theme.of(context).textTheme.titleMedium)),
                  if (selected.length >= 50) ...[
                    const SizedBox(height: 8),
                    const Notice('已达到 50 台上限。请先取消其他设备，再添加设备。'),
                  ],
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    FilterChip(
                        label: const Text('仅看已选'),
                        selected: onlySelected,
                        onSelected: changeSelectedFilter),
                    TextButton(
                        onPressed: selected.isEmpty ? null : clearSelection,
                        child: const Text('清空选择')),
                  ]),
                  Text('已加载 ${devices.length} 台${cursor == null ? '' : '，还有更多设备'}',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  if (loading) const LinearProgressIndicator(),
                  if (error != null) ...[
                    if (cursorInvalid) ...[
                      const Notice(
                          '分页信息无法继续使用，已保留已加载设备和当前选择。可继续核对已选设备；需要继续浏览时，请重新加载并重新选择。',
                          warning: true),
                      TextButton.icon(
                          onPressed: loading ? null : reloadFromStart,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重新加载并清空选择')),
                    ] else
                      FailureView(error!, retry: () => load(more: cursor != null)),
                  ],
                  SizedBox(
                      height: (MediaQuery.sizeOf(context).height * .36)
                          .clamp(100.0, 320.0).toDouble(),
                      child: visible.isEmpty
                          ? Center(child: Text(devices.isEmpty
                              ? loading
                                  ? '正在加载设备…'
                                  : error != null
                                      ? '设备尚未加载，请重试。'
                                      : removing
                                          ? '组内没有设备。'
                                          : '没有可选设备，请先注册并激活机构设备。'
                              : onlySelected && selected.isEmpty
                                  ? '还没有选择设备，关闭“仅看已选”后继续选择。'
                                  : onlySelected
                                      ? '已选设备中没有匹配项，请调整或清除搜索。'
                                      : cursor != null
                                          ? '已加载设备中没有匹配项，可调整搜索或继续加载更多。'
                                          : '没有匹配的设备，请调整或清除搜索。'))
                          : ListView.builder(
                              itemCount: visible.length,
                              itemBuilder: (context, index) {
                                final row = visible[index];
                                final id = idOf(row);
                                final active = row['state'] == 'ACTIVE';
                                final checked = selected.containsKey(id);
                                return CheckboxListTile(
                                  key: ValueKey(id),
                                  value: checked,
                                  onChanged: (removing || active) &&
                                          (checked || selected.length < 50)
                                      ? (_) => toggle(row)
                                      : null,
                                  title: Text(row['displayName'] as String),
                                  subtitle: Text(
                                      '${label(row['platform'])} · ${label(row['state'])}'
                                      '${removing ? ' · ${label(row['membershipStatus'])}' : ''}\n设备 $id'),
                                  isThreeLine: true,
                                  controlAffinity: ListTileControlAffinity.leading,
                                );
                              })),
                  if (cursor != null && !cursorInvalid)
                    TextButton.icon(
                        onPressed: loading ? null : () => load(more: true),
                        icon: const Icon(Icons.expand_more),
                        label: const Text('加载更多设备')),
                ])),
        actions: [
          TextButton(onPressed: close, child: const Text('取消')),
          FilledButton(
              onPressed: selected.isEmpty || selected.length > 50 ? null : confirm,
              child: Text('核对并${removing ? '移出' : '加入'} ${selected.length} 台')),
        ]);
  }
}
