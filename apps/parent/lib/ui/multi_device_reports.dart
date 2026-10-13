import 'package:flutter/material.dart';
import 'package:usage_reporting/usage_reporting.dart';
import 'package:usage_report_ui/usage_report_ui.dart';
import '../core/paged_collection.dart';
import '../core/parent_session.dart';
import '../core/report_selection.dart';
import '../core/usage_reports.dart';
import 'observation_settings_page.dart';

/// Both routes retain the exact adult account/role/workspace from opening.
mixin _ReportScope<T extends StatefulWidget> on State<T> {
  ParentSession get session;
  late final String tenant, actor, role;
  bool get current =>
      mounted &&
      session.authenticated &&
      session.canDecide &&
      session.tenant?['id'] == tenant &&
      session.profile?['subject'] == actor &&
      session.role == role;
  void clearPrivateData();
  @override
  void initState() {
    super.initState();
    tenant = session.tenant!['id'];
    actor = session.profile!['subject'];
    role = session.role;
    session.addListener(_changed);
  }

  void _changed() {
    if (!mounted || current) return;
    clearPrivateData();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    session.removeListener(_changed);
    super.dispose();
  }
}

class ParentReportDevicePicker extends StatefulWidget {
  final ParentSession session;

  /// Start with tap-to-view; dedicated selection callers retain multi-select.
  final bool browseFirst;
  final Future<void> Function(List<UsageReportTarget>)? onSelected;
  const ParentReportDevicePicker(
      {super.key,
      required this.session,
      this.onSelected,
      this.browseFirst = false});
  @override
  State<ParentReportDevicePicker> createState() =>
      _ParentReportDevicePickerState();
}

class _ParentReportDevicePickerState extends State<ParentReportDevicePicker>
    with WidgetsBindingObserver, _ReportScope {
  @override
  ParentSession get session => widget.session;
  PagedCollection? devices;
  final selection = ParentReportSelection();
  final search = TextEditingController();
  bool foreground = true, opening = false;
  late bool selecting;
  String? error;
  @override
  void initState() {
    super.initState();
    selecting = !widget.browseFirst;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    if (foreground) {
      devices = PagedCollection(session.api, '/tenants/$tenant/devices',
          isCurrent: () => current && foreground);
    }
  }

  @override
  void clearPrivateData() {
    devices?.dispose();
    devices = null;
    selection.clear();
    search.clear();
    error = null;
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) clearPrivateData();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    devices?.dispose();
    search.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _reload() async {
    if (!current || !foreground || opening) return;
    setState(() {
      selection.clear();
      search.clear();
      error = null;
    });
    if (devices == null) {
      setState(() => devices = PagedCollection(
          session.api, '/tenants/$tenant/devices',
          isCurrent: () => current && foreground));
    } else {
      await devices!.reload();
    }
  }

  void _add(Iterable<UsageReportTarget> values) {
    if (!current || !foreground || opening) return;
    setState(() {
      try {
        selection.add(values);
        error = null;
      } on FormatException catch (e) {
        error = e.message;
      } catch (e) {
        error = '$e';
      }
    });
  }

  Future<void> _open([List<UsageReportTarget>? direct]) async {
    if (!current || !foreground || opening) return;
    final targets = direct ?? selection.targets;
    if (targets.isEmpty) return;
    setState(() => opening = true);
    try {
      if (widget.onSelected != null) {
        await widget.onSelected!(targets);
      } else {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ParentMultiDeviceReportPage(
                session: session, targets: targets)));
      }
    } finally {
      if (current) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar:
          AppBar(title: Text(widget.browseFirst ? '使用情况' : '选择报告设备'), actions: [
        if (widget.browseFirst && current && foreground)
          TextButton(
              onPressed: opening
                  ? null
                  : () => setState(() {
                        selecting = !selecting;
                        selection.clear();
                        error = null;
                      }),
              child: Text(selecting ? '取消多选' : '多选')),
      ]),
      bottomNavigationBar: !current || !foreground || !selecting
          ? null
          : SafeArea(
              child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                        '已明确选择 ${selection.length} / ${ParentReportSelection.limit} 台'),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                        onPressed:
                            opening || selection.length == 0 ? null : _open,
                        icon: const Icon(Icons.bar_chart_outlined),
                        label: const Text('查看所选设备报告')),
                  ]))),
      body: !current || !foreground
          ? const Center(child: Text('设备选择已隐藏。'))
          : devices == null
              ? Center(
                  child: OutlinedButton(
                      onPressed: _reload, child: const Text('重新读取设备')))
              : AnimatedBuilder(
                  animation: devices!,
                  builder: (context, _) {
                    final collection = devices!;
                    final filter = search.text.trim().toLowerCase();
                    final visible = collection.items
                        .where((d) =>
                            '${d['displayName']} ${d['id']} ${d['subjectId']}'
                                .toLowerCase()
                                .contains(filter))
                        .toList();
                    final available = visible
                        .map(parentReportTarget)
                        .whereType<UsageReportTarget>()
                        .toList();
                    return RefreshIndicator(
                        onRefresh: _reload,
                        child: ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(20),
                            itemCount: visible.length + 3,
                            itemBuilder: (context, index) {
                              if (index == 0) {
                                return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(selecting ? '一起了解使用情况' : '想了解哪台设备？',
                                          style: Theme.of(context)
                                              .textTheme
                                              .headlineSmall),
                                      const SizedBox(height: 8),
                                      Text(selecting
                                          ? '选择最多 20 台，统一查看同一时段。'
                                          : '点设备直接查看最近 7 天，也可以多选。'),
                                      const SizedBox(height: 12),
                                      TextField(
                                          controller: search,
                                          onChanged: (_) => setState(() {}),
                                          decoration: InputDecoration(
                                              labelText: '筛选已加载设备',
                                              filled: true,
                                              border: const OutlineInputBorder(
                                                  borderRadius:
                                                      BorderRadius.all(
                                                          Radius.circular(16)),
                                                  borderSide: BorderSide.none),
                                              suffixIcon: search.text.isEmpty
                                                  ? null
                                                  : IconButton(
                                                      tooltip: '清除搜索',
                                                      icon: const Icon(
                                                          Icons.close),
                                                      onPressed: () => setState(
                                                          search.clear)),
                                              prefixIcon:
                                                  const Icon(Icons.search))),
                                      const SizedBox(height: 12),
                                      Text(
                                          '已加载 ${collection.items.length} 台 · 匹配 ${visible.length} 台${collection.hasMore ? ' · 下方可加载更多' : ''}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall),
                                      if (selecting)
                                        Wrap(spacing: 8, children: [
                                          TextButton(
                                              onPressed:
                                                  opening || available.isEmpty
                                                      ? null
                                                      : () => _add(available),
                                              child: const Text('选择筛选结果')),
                                          TextButton(
                                              onPressed: opening ||
                                                      selection.length == 0
                                                  ? null
                                                  : () =>
                                                      setState(selection.clear),
                                              child: const Text('清空选择')),
                                        ]),
                                      if (selection.length > 0)
                                        ExpansionTile(
                                            title: Text(
                                                '核对已选 ${selection.length} 台'),
                                            children: [
                                              for (final t in selection.targets)
                                                ListTile(
                                                    title: Text(t.displayName),
                                                    subtitle: Text(
                                                        '设备：${t.deviceId}\n注册：${t.registrationId}'),
                                                    trailing: IconButton(
                                                        tooltip:
                                                            '移除 ${t.displayName}',
                                                        icon: const Icon(
                                                            Icons.close),
                                                        onPressed: opening
                                                            ? null
                                                            : () => setState(() =>
                                                                selection.remove(
                                                                    t.deviceId)))),
                                            ]),
                                      if (error != null)
                                        Semantics(
                                            liveRegion: true,
                                            child: Text(error!)),
                                      if (collection.error != null) ...[
                                        Text('${collection.error}'),
                                        TextButton(
                                            onPressed: _reload,
                                            child: const Text('重新读取'))
                                      ],
                                      if (collection.loading)
                                        const LinearProgressIndicator(),
                                      if (collection.loaded && visible.isEmpty)
                                        const Padding(
                                            padding: EdgeInsets.all(20),
                                            child: Text('已加载目录中没有匹配设备。')),
                                    ]);
                              }
                              if (index == visible.length + 2) {
                                return const Padding(
                                    padding: EdgeInsets.only(top: 16),
                                    child: Text(
                                        '仅展示已授权的使用记录；缺少数据不代表没有使用。下拉刷新会清空已选设备。',
                                        style: TextStyle(fontSize: 12)));
                              }
                              if (index == visible.length + 1) {
                                return Column(children: [
                                  if (collection.loadingMore)
                                    const LinearProgressIndicator(),
                                  if (collection.hasMore)
                                    TextButton(
                                        onPressed:
                                            collection.loadingMore || opening
                                                ? null
                                                : collection.loadMore,
                                        child: const Text('加载更多设备')),
                                ]);
                              }
                              final value = visible[index - 1],
                                  target = parentReportTarget(value);
                              final id = value['id'] as String,
                                  checked = selection.contains(id);
                              if (!selecting) {
                                final scheme = Theme.of(context).colorScheme;
                                return Card(
                                    key: ValueKey(id),
                                    margin: const EdgeInsets.only(top: 12),
                                    child: ListTile(
                                        contentPadding:
                                            const EdgeInsets.all(16),
                                        leading: CircleAvatar(
                                            backgroundColor:
                                                scheme.primaryContainer,
                                            child: Icon(
                                                target?.platform == 'ANDROID_TV'
                                                    ? Icons.tv
                                                    : Icons.tablet_android,
                                                color:
                                                    scheme.onPrimaryContainer)),
                                        title: Text(
                                            value['displayName'] is String
                                                ? value['displayName']
                                                : '设备信息待核对'),
                                        subtitle: Text(target == null
                                            ? '暂不可查看 · 请核对注册资料'
                                            : '${target.platform == 'ANDROID_TV' ? '电视' : '手机 / 平板'} · 查看使用记录'),
                                        trailing:
                                            const Icon(Icons.chevron_right),
                                        onTap: opening || target == null
                                            ? null
                                            : () => _open([target])));
                              }
                              return Card(
                                  key: ValueKey(id),
                                  child: CheckboxListTile(
                                      value: checked,
                                      title: Text(value['displayName'] is String
                                          ? value['displayName']
                                          : '设备信息待核对'),
                                      subtitle: Text(target == null
                                          ? '注册未启用、平台不支持或资料不完整，不能选择。'
                                          : '${target.platform == 'ANDROID_TV' ? '电视' : '手机 / 平板'} · ${target.deviceId.substring(0, 8)}'),
                                      onChanged: opening || target == null
                                          ? null
                                          : (chosen) {
                                              if (chosen == true) {
                                                _add([target]);
                                              } else {
                                                setState(
                                                    () => selection.remove(id));
                                              }
                                            }));
                            }));
                  }));
}

class ParentMultiDeviceReportPage extends StatefulWidget {
  final ParentSession session;
  final List<UsageReportTarget> targets;
  final ParentUsageReportLoader? loader;
  ParentMultiDeviceReportPage(
      {super.key,
      required this.session,
      required List<UsageReportTarget> targets,
      this.loader})
      : targets = List.unmodifiable(targets);
  @override
  State<ParentMultiDeviceReportPage> createState() =>
      _ParentMultiDeviceReportPageState();
}

class _ParentMultiDeviceReportPageState
    extends State<ParentMultiDeviceReportPage>
    with WidgetsBindingObserver, _ReportScope {
  @override
  ParentSession get session => widget.session;
  late final ParentUsageReportLoader loader;
  bool foreground = true, managing = false;
  @override
  void initState() {
    super.initState();
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    loader = widget.loader ??
        ParentUsageReportLoader(
            api: session.api,
            tenant: tenant,
            token: session.token,
            available: () => current && foreground && !managing);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void clearPrivateData() {
    loader.cancel();
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) loader.cancel();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    loader.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _consent(UsageReportTarget target) async {
    if (!current || !foreground || managing) return;
    loader.cancel();
    setState(() => managing = true);
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            ParentObservationPage(session: session, target: target)));
    if (current) setState(() => managing = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          title: Text(widget.targets.length == 1
              ? widget.targets.single.displayName
              : '所选 ${widget.targets.length} 台设备报告')),
      body: !current || managing
          ? const SizedBox.shrink()
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (foreground)
                      ExpansionTile(title: const Text('核对范围与观察授权'), children: [
                        for (final t in widget.targets)
                          ListTile(
                              title: Text(t.displayName),
                              subtitle: Text('设备：${t.deviceId}'),
                              trailing: IconButton(
                                  tooltip: '管理 ${t.displayName} 的观察授权',
                                  icon: const Icon(Icons.privacy_tip_outlined),
                                  onPressed: () => _consent(t))),
                      ]),
                    DeviceUsageReportView(
                        compactControls: true,
                        onManageObservation: (id) => _consent(
                            widget.targets.firstWhere((t) => t.deviceId == id)),
                        targets: widget.targets,
                        title:
                            widget.targets.length == 1 ? '设备使用情况' : '多设备使用情况',
                        description: '了解使用趋势，安排更合适的学习和休息。',
                        notAuthorizedMessage: '这台设备尚未授权使用观察。由管理员确认后，才能展示使用记录。',
                        load: (window) => loader.load(UsageReportQuery(
                            targets: widget.targets,
                            from: window.from,
                            to: window.to,
                            timeZone: window.timeZone,
                            period: window.period)),
                        cancel: loader.cancel,
                        accessChanges: session,
                        available: () => current && foreground && !managing,
                        timeZone: session.tenant?['timeZone'] as String? ??
                            'Asia/Shanghai'),
                  ])));
}
