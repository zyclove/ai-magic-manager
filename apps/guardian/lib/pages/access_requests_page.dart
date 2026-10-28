import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/approval_decision.dart';
import '../core/labels.dart';
import '../ui/design.dart';
import '../ui/resource_page.dart';

/// A pending query can return a row reconciled to another state during reading.
bool includePendingAccessRequest(Json row) {
  final state = row['state'];
  if (state is! String || !accessRequestStates.contains(state)) {
    throw const ApiFailure(502, 'INVALID_RESPONSE');
  }
  return state == 'PENDING';
}

class AccessRequestsPage extends StatefulWidget {
  final Api api;
  final String path, role;
  final bool Function() isCurrent;
  final Future<bool> Function(Json, ResourceActionLease) onOpenChanged;
  final Future<bool> Function(ResourceActionLease)? createChanged;
  final VoidCallback? reauth;
  final bool pendingFilter;
  final ValueChanged<bool> onFilterChanged;

  const AccessRequestsPage(
      {super.key,
      required this.api,
      required this.path,
      required this.role,
      required this.isCurrent,
      required this.onOpenChanged,
      required this.pendingFilter,
      required this.onFilterChanged,
      this.createChanged,
      this.reauth});

  @override
  State<AccessRequestsPage> createState() => _AccessRequestsPageState();
}

class _AccessRequestsPageState extends State<AccessRequestsPage> {
  bool get pending => widget.pendingFilter;
  bool busy = false;
  bool active = true;
  int viewGeneration = 0;
  ModalRoute<dynamic>? owner;

  bool get requester => const ['CHILD', 'TEACHER'].contains(widget.role);
  bool get ownerInteractive =>
      mounted && active &&
      widget.isCurrent() &&
      (owner == null || (owner!.isActive && owner!.isCurrent));
  bool get interactive => ownerInteractive && !busy;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    owner = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(AccessRequestsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.api, widget.api) || oldWidget.path != widget.path ||
        oldWidget.role != widget.role || oldWidget.pendingFilter != pending) {
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
    if (!interactive || viewGeneration != view ||
        selection.length != 1 || selection.single == pending) {
      return;
    }
    setState(() => viewGeneration++);
    widget.onFilterChanged(selection.single);
  }

  Future<bool> perform(Future<bool> Function() callback,
      ResourceActionLease lease, int view) async {
    if (!interactive || !lease.current || viewGeneration != view) return false;
    setState(() => busy = true);
    try {
      final changed = await callback();
      return changed && lease.current && viewGeneration == view;
    } finally {
      if (mounted && viewGeneration == view) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auditor = widget.role == 'AUDITOR';
    final view = viewGeneration;
    final open = widget.onOpenChanged;
    final create = widget.createChanged;
    return ResourcePage(
        api: widget.api,
        path: pending ? '${widget.path}?state=PENDING' : widget.path,
        includeRow: pending ? includePendingAccessRequest : null,
        isCurrent: widget.isCurrent,
        canInteract: () => ownerInteractive,
        title: requester ? '我的访问申请' : '访问审批',
        subtitle: widget.role == 'TEACHER'
            ? '仅查看当前授课范围内由本人提交的申请；范围失效后申请将同步失效。'
            : requester
                ? '查看自己的临时访问申请与处理结果。'
                : '查看临时访问请求，保留有期限的决定记录。',
        toolbar: [
          SegmentedButton<bool>(
              key: const Key('access-requests-state-filter'),
              segments: const [
                ButtonSegment(value: true, label: Text('待处理')),
                ButtonSegment(value: false, label: Text('全部')),
              ],
              selected: {pending},
              onSelectionChanged: interactive
                  ? (selection) => select(selection, view) : null),
        ],
        columns: [
          ColumnSpec('对象',
              (row) => _requestTarget(row, showNames: !auditor)),
          ColumnSpec('内容',
              (row) => _requestContent(row, showNames: !auditor)),
          ColumnSpec('状态', (row) => row['state'] is String
              ? StatusTag(row['state'])
              : const Text('状态未提供')),
          ColumnSpec('创建时间', (row) => Text(_createdAt(row['createdAt']))),
        ],
        onOpenChanged: (row, lease) =>
            perform(() => open(row, lease), lease, view),
        onCreateChanged: requester && create != null ? (lease) =>
            perform(() => create(lease), lease, view) : null,
        createLabel: '申请临时访问',
        reauth: widget.reauth,
        emptyTitle: pending ? '已加载记录中暂无待处理申请' : '暂无访问申请',
        emptyDescription: pending
            ? '可切换“全部”查看处理记录；有后续记录时可继续加载。'
            : requester
                ? '选择范围内的设备，向管理员说明需要临时访问的应用与时长。'
                : '儿童或教师提交申请后，将在这里显示。',
        notice: '批准后设备可获取带固定截止时间的签名文档。'
            '接收与保存回执单独记录；当前尚未接入设备例外执行。');
  }
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

String _nameOrId(Json row, String name, String id,
        {required bool showNames}) =>
    (showNames ? _text(row[name]) : null) ?? _text(row[id]) ?? '未提供';

Widget _requestTarget(Json row, {required bool showNames}) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('成员：${_nameOrId(row, 'subjectName', 'subjectId', showNames: showNames)}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('设备：${_nameOrId(row, 'deviceName', 'deviceId', showNames: showNames)}',
              style: const TextStyle(color: muted)),
        ]);

Widget _requestContent(Json row, {required bool showNames}) {
  final package = showNames ? _text(row['applicationPackageName']) : null;
  final reason = _text(row['reason']);
  final seconds = row['requestedWindowSeconds'];
  return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_nameOrId(row, 'applicationName', 'applicationId',
            showNames: showNames)),
        if (package != null)
          Text('软件包：$package', style: const TextStyle(color: muted)),
        Text(seconds is int && seconds > 0
            ? '申请时长：${approvalDuration(seconds)}'
            : '申请时长未提供'),
        if (reason != null) ...[
          const SizedBox(height: 4),
          Text(reason, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: muted)),
        ],
      ]);
}

String _createdAt(Object? value) {
  if (value is String && DateTime.tryParse(value) != null) return dateLabel(value);
  if (value is int) {
    try {
      return dateLabel(value);
    } on ArgumentError {
      return '时间格式异常';
    }
  }
  return '时间未提供';
}
