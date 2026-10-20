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
  List<Json> devices = const [];
  String? cursor;
  Object? error;
  bool loading = false;
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
    if (!current || selected.isEmpty) return;
    finish(List<Json>.unmodifiable(selected.values));
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
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    if (!current || loading || (more && cursor == null)) {
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
        setState(() => error = failure);
      }
    } finally {
      if (mounted && _active && permitted && generation == requested) {
        setState(() => loading = false);
      }
    }
  }

  void toggle(Json row) {
    if (!current || (!removing && row['state'] != 'ACTIVE')) return;
    final id = idOf(row);
    if (!devices.any((item) => idOf(item) == id &&
        item['registrationId'] == row['registrationId'])) return;
    setState(() {
      if (selected.containsKey(id)) {
        selected.remove(id);
      } else if (selected.length < 50) {
        selected[id] = row;
      }
    });
  }

  @override
  Widget build(BuildContext context) => !permitted
      ? AlertDialog(
          title: const Text('工作空间或权限已变化'),
          content: const Text('已隐藏原设备选择。请关闭窗口，在当前工作空间重新打开。'),
          actions: [TextButton(onPressed: () {
            if (_route?.isCurrent == true) finish();
          }, child: const Text('关闭'))])
      : Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680, maxHeight: 720),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(removing ? '批量移出设备组' : '批量加入设备组',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(removing
                    ? '可清理停用、旧注册周期及其他成员；单次最多 50 台。移出不撤销设备注册或已有独立策略。'
                    : '仅可选择已激活的本机构设备；单次最多 50 台。确认时会重新核对每台设备的注册周期。'),
                const SizedBox(height: 12),
                Text('已选择 ${selected.length} / 50 台',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (loading) const LinearProgressIndicator(),
                if (error != null)
                  FailureView(error!, retry: () => load(more: cursor != null)),
                Expanded(
                  child: devices.isEmpty && !loading && error == null
                      ? EmptyView(removing ? '组内没有设备' : '没有可选设备',
                          removing ? '当前设备组已没有需要清理的成员。' : '请先注册并激活机构设备。')
                      : ListView.builder(
                          itemCount: devices.length + (cursor == null ? 0 : 1),
                          itemBuilder: (context, index) {
                            if (index == devices.length) {
                              return TextButton.icon(
                                onPressed:
                                    loading ? null : () => load(more: true),
                                icon: const Icon(Icons.expand_more),
                                label: const Text('加载更多设备'),
                              );
                            }
                            final row = devices[index];
                            final id = idOf(row);
                            final active = row['state'] == 'ACTIVE';
                            final checked = selected.containsKey(id);
                            return CheckboxListTile(
                              value: checked,
                              onChanged: (removing || active) &&
                                      (checked || selected.length < 50)
                                  ? (_) => toggle(row)
                                  : null,
                              title: Text(row['displayName'] as String),
                              subtitle: Text(
                                  '${label(row['platform'])} · ${label(row['state'])}'
                                  '${removing ? ' · ${label(row['membershipStatus'])}' : ''}\n$id'),
                              isThreeLine: true,
                              controlAffinity: ListTileControlAffinity.leading,
                            );
                          },
                        ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    TextButton(
                        onPressed: close,
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: selected.isEmpty ? null : confirm,
                        child: Text(
                            '核对并${removing ? '移出' : '加入'} ${selected.length} 台')),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
}
