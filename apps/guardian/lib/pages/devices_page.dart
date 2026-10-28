import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/labels.dart';
import '../ui/design.dart';
import '../ui/device_observation_status.dart';
import '../ui/resource_page.dart';

/// Connection filtering belongs to the server; the host owns the selected URL.
class DevicesPage extends StatefulWidget {
  final Api api;
  final String path;
  final bool needsConnectionCheck;
  final bool Function() isCurrent;
  final Future<bool> Function(Json, ResourceActionLease) onOpenChanged;
  final ValueChanged<bool> onFilterChanged;
  final Future<bool> Function(ResourceActionLease)?
      createChanged, findEnrollmentChanged;
  final VoidCallback? reauth;

  const DevicesPage(
      {super.key,
      required this.api,
      required this.path,
      required this.needsConnectionCheck,
      required this.isCurrent,
      required this.onOpenChanged,
      required this.onFilterChanged,
      this.createChanged,
      this.findEnrollmentChanged,
      this.reauth});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  final resources = GlobalKey<ResourcePageState>();
  bool busy = false;
  bool active = true;
  int viewGeneration = 0;
  ModalRoute<dynamic>? owner;

  bool get pageCurrent => mounted && active && widget.isCurrent();
  bool get ownerInteractive =>
      pageCurrent &&
      (owner == null || (owner!.isActive && owner!.isCurrent));
  bool get interactive => ownerInteractive && !busy;
  bool viewCurrent(int view) => pageCurrent && viewGeneration == view;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    owner = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(DevicesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.api, widget.api) ||
        oldWidget.path != widget.path ||
        oldWidget.needsConnectionCheck != widget.needsConnectionCheck) {
      viewGeneration++;
      busy = false;
    }
  }

  @override
  void deactivate() {
    active = false;
    viewGeneration++;
    busy = false;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    active = true;
  }

  void select(Set<bool> selection, int view) {
    if (!interactive || !viewCurrent(view) ||
        selection.length != 1 ||
        selection.single == widget.needsConnectionCheck) return;
    setState(() => viewGeneration++);
    widget.onFilterChanged(selection.single);
  }

  Future<bool> perform(Future<bool> Function() callback,
      ResourceActionLease lease, int view) async {
    if (!interactive || !viewCurrent(view) || !lease.current) return false;
    setState(() => busy = true);
    try {
      final changed = await callback();
      return changed && viewCurrent(view) && lease.current;
    } finally {
      if (mounted && viewGeneration == view) setState(() => busy = false);
    }
  }

  Future<void> findEnrollment(
      Future<bool> Function(ResourceActionLease) callback, int view) async {
    final resource = resources.currentState;
    if (!interactive || !viewCurrent(view) || resource == null ||
        !identical(widget.findEnrollmentChanged, callback)) return;
    // Lookup can continue into a registration change. Only that signal requests
    // a read, within the same table action lock and original resource lease.
    await resource.action((lease) async {
      final changed = await perform(() => callback(lease), lease, view);
      if (changed && viewCurrent(view) && lease.current) await resource.load();
    }, refresh: false);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.needsConnectionCheck;
    final view = viewGeneration;
    final onOpenChanged = widget.onOpenChanged;
    final createChanged = widget.createChanged;
    final findEnrollmentChanged = widget.findEnrollmentChanged;
    return ResourcePage(
        key: resources,
        api: widget.api,
        path: filtered ? '${widget.path}?connection=NEEDS_CHECK' : widget.path,
        isCurrent: () => pageCurrent,
        // ResourcePage keeps its own row/create action progress visible while
        // perform blocks the externally controlled filter.
        canInteract: () => ownerInteractive,
        title: '设备管理',
        subtitle: '查看设备注册、连接状态和实际管理能力。',
        toolbar: [
          SegmentedButton<bool>(
              key: const Key('devices-connection-filter'),
              segments: const [
                ButtonSegment(value: false, label: Text('全部设备')),
                ButtonSegment(value: true, label: Text('待检查连接')),
              ],
              selected: {filtered},
              onSelectionChanged: interactive
                  ? (selection) => select(selection, view)
                  : null),
          if (findEnrollmentChanged != null)
            TextButton(
                key: const Key('devices-find-enrollment'),
                onPressed: interactive
                    ? () => findEnrollment(findEnrollmentChanged, view)
                    : null,
                child: const Text('查询注册进度')),
        ],
        columns: [
          ColumnSpec('设备', (row) => _deviceName(row)),
          ColumnSpec('平台', (row) => Text(label(row['platform']))),
          ColumnSpec('注册状态', (row) => StatusTag(row['state'])),
          ColumnSpec('心跳观察',
              (row) => DeviceObservationStatus(row['observationStatus'])),
          ColumnSpec('最近心跳',
              (row) => Text(dateLabel(row['lastHeartbeatAt']))),
        ],
        onOpenChanged: (row, lease) =>
            perform(() => onOpenChanged(row, lease), lease, view),
        onCreateChanged: createChanged == null ? null : (lease) =>
            perform(() => createChanged(lease), lease, view),
        createLabel: '添加设备',
        reauth: widget.reauth,
        emptyTitle: filtered ? '暂无待检查连接的设备' : '尚未连接设备',
        emptyDescription: filtered
            ? '可切换“全部设备”查看其他设备；有后续记录时可继续加载。'
            : createChanged == null
                ? '当前工作空间暂无可显示的设备，管理员添加后将在这里显示。'
                : '先创建儿童档案，再通过配对流程绑定 Android 或 TV 设备。',
        notice: '心跳仅反映服务端近期能否观察设备。心跳过期需检查连接，'
            '不能据此判断规则已失效。策略执行仍以设备能力和执行回执为准。');
  }
}

Widget _deviceName(Json row) {
  String? text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;
  final name = text(row['displayName']) ?? text(row['id']) ?? '设备名称未提供';
  return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
              color: canvas, borderRadius: BorderRadius.circular(8)),
          child: Icon(
              row['platform'] == 'ANDROID_TV'
                  ? Icons.tv_outlined
                  : Icons.smartphone_outlined,
              size: 20,
              color: navy)),
      const SizedBox(width: 12),
      Flexible(
          child: Text(name,
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis))
    ]);
}
