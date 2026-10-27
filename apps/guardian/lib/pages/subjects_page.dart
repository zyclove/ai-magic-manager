import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/resource_page.dart';
import 'device_subflow_scope.dart';

class SubjectsPage extends StatefulWidget {
  final Session session;
  final Future<bool> Function(Listenable accessChanges,
      bool Function() hasAccess) onCreate;
  final Future<bool> Function(Json row, Listenable accessChanges,
      bool Function() hasAccess) onOpen;
  const SubjectsPage({super.key, required this.session,
      required this.onCreate, required this.onOpen});

  @override
  State<SubjectsPage> createState() => _SubjectsPageState();
}

class _SubjectsPageState extends State<SubjectsPage> {
  late final DeviceSubflowScope _scope;
  late final String _root;
  bool _archived = false, _acting = false, _retired = false;
  bool _rebuildPending = false;
  int _viewGeneration = 0;
  ValueNotifier<bool>? _operationLifetime, _retiringLifetime;
  Session get s => widget.session;
  bool get current => mounted && !_retired && _scope.current;

  @override
  void initState() {
    super.initState();
    final session = s;
    _root = session.tenant == null ? '' : session.root;
    _scope = DeviceSubflowScope(session,
        permitted: () => mounted && !_retired &&
            identical(widget.session, session) && session.tenant != null &&
            session.root == _root && session.canOpen('subjects'));
    _scope.addListener(_accessChanged);
  }

  void _accessChanged() {
    if (current) return;
    _retireOperation();
    if (!mounted || _retired || _rebuildPending) return;
    _rebuildPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildPending = false;
      if (mounted && !_retired) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _retireOperation() {
    final lifetime = _operationLifetime;
    if (lifetime == null || identical(_retiringLifetime, lifetime)) return;
    _retiringLifetime = lifetime;
    // The operation owns this notifier until every dialog route has finished.
    // Page authority stops synchronously; notify after any pending form build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (identical(_operationLifetime, lifetime)) lifetime.value = false;
      if (identical(_retiringLifetime, lifetime)) _retiringLifetime = null;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didUpdateWidget(SubjectsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      _retired = true;
      _viewGeneration++;
      _retireOperation();
    }
  }

  @override
  void deactivate() {
    _retired = true;
    _viewGeneration++;
    _retireOperation();
    super.deactivate();
  }

  @override
  void dispose() {
    _retired = true;
    _retireOperation();
    _scope.removeListener(_accessChanged);
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!current) {
      return const Notice('工作空间或权限已变化，请重新打开儿童档案。', warning: true);
    }
    final managed = s.canWrite;
    final view = _viewGeneration;
    final route = ModalRoute.of(context);
    bool viewCurrent() => current && _viewGeneration == view;
    bool interactive() => viewCurrent() && !_acting &&
        (route?.isCurrent ?? true);

    Future<bool> act(Future<bool> Function(Listenable, bool Function()) action) async {
      if (!interactive()) return false;
      final lifetime = ValueNotifier(true);
      _operationLifetime = lifetime;
      bool permitted() => viewCurrent() && lifetime.value;
      setState(() => _acting = true);
      try {
        final needsReview = await action(lifetime, permitted);
        return permitted() && needsReview;
      } finally {
        if (identical(_operationLifetime, lifetime)) _operationLifetime = null;
        if (identical(_retiringLifetime, lifetime)) _retiringLifetime = null;
        lifetime.dispose();
        if (mounted && !_retired) setState(() => _acting = false);
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_acting && (route?.isCurrent ?? true))
        const LinearProgressIndicator(),
      ResourcePage(
        key: ValueKey((_root, managed, view)),
        api: _scope.api,
        path: managed
            ? '$_root/subjects/management${_archived ? '?includeArchived=true' : ''}'
            : '$_root/subjects',
        isCurrent: viewCurrent,
        canInteract: interactive,
        title: '儿童档案',
        subtitle: managed
            ? '按年龄段维护档案。默认显示使用中的档案，已归档档案可只读查看。'
            : '查看获授的儿童档案及年龄段。',
        emptyTitle: _archived ? '暂无可查看档案' : '暂无使用中的儿童档案',
        emptyDescription: managed
            ? '添加档案只需昵称和年龄段，不需要完整生日。'
            : '请联系工作空间管理员核对档案访问范围。',
        createLabel: '添加儿童',
        onCreateChanged: managed ? () => act(widget.onCreate) : null,
        onOpenChanged: (row) => act((changes, permitted) =>
            widget.onOpen(row, changes, permitted)),
        reauth: () { if (interactive()) s.login(stepUp: true); },
        toolbar: [
          if (managed)
            FilterChip(
                label: const Text('包含已归档'),
                selected: _archived,
                onSelected: _acting ? null : (value) {
                  if (!interactive() || value == _archived) return;
                  setState(() {
                    _archived = value;
                    _viewGeneration++;
                  });
                })
        ],
        columns: [
          ColumnSpec('儿童', (row) => Row(mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.person_outline, size: 20, color: navy),
                const SizedBox(width: 12),
                Flexible(child: Text(row['nickname']?.toString() ?? '—',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis))
              ])),
          ColumnSpec('年龄段', (row) => Text(label(row['ageBand']))),
          if (managed)
            ColumnSpec('状态', (row) => Text(switch (row['state']) {
              'ACTIVE' => '使用中',
              'ARCHIVED' => '已归档',
              _ => '状态未知',
            })),
          ColumnSpec('档案编号', (row) => Tooltip(
              message: row['id']?.toString() ?? '',
              child: Text(shortId(row['id']),
                  style: const TextStyle(color: muted))))
        ])
    ]);
  }
}
