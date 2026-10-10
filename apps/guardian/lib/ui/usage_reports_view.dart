import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/api.dart';
import '../core/application_classification.dart';
import '../core/usage_reports.dart';
import '../core/usage_report_jobs.dart';
import '../core/observation.dart' show observationProfile;
import 'design.dart';
import 'usage_trend_view.dart';
import 'report_configurations_view.dart';
import 'usage_report_device_picker.dart';

class UsageReportsView extends StatefulWidget {
  final UsageReportRepository repository;
  final Future<List<UsageReportTarget>> Function() loadTargets;
  final Future<List<UsageReportScope>> Function()? loadScopes;
  final Future<UsageReportScope> Function(UsageReportScope)? resolveScope;
  final String timeZone;
  final Listenable? accessChanges;
  final VoidCallback? reauth;
  final ValueChanged<UsageReportJobDraft>? onBackground;
  final VoidCallback? onJobs;
  const UsageReportsView(
      {super.key,
      required this.repository,
      required this.loadTargets,
      this.loadScopes,
      this.resolveScope,
      required this.timeZone,
      this.accessChanges,
      this.onBackground,
      this.onJobs,
      this.reauth});
  @override
  State<UsageReportsView> createState() => _UsageReportsViewState();
}

class _UsageReportsViewState extends State<UsageReportsView>
    with WidgetsBindingObserver {
  List<UsageReportTarget>? targets;
  List<UsageReportScope> scopes = const [UsageReportScope.devices()];
  UsageReportScope scope = const UsageReportScope.devices();
  List<UsageReportTarget> get available =>
      (targets ?? const <UsageReportTarget>[]).where(scope.accepts).toList();
  final selected = <String>{};
  int get maxDevices => widget.onBackground == null ? 20 : 200;
  Object? optionsError, error;
  UsageReport? report;
  UsageReportQuery? applied;
  bool loading = false, invalidated = false;
  bool foreground = true;
  bool get current =>
      mounted && foreground && !invalidated && widget.repository.current();
  int generation = 0;
  ModalRoute<dynamic>? activeDialog;
  String period = 'DAY';
  String categoryFilter = 'ALL';
  late String zone;
  late DateTimeRange dates;
  @override
  void initState() {
    super.initState();
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    zone = widget.timeZone;
    try {
      usageLocation(zone);
    } on UsageReportFailure {
      zone = 'UTC';
    }
    final today = usageLocalTime(DateTime.now().millisecondsSinceEpoch, zone);
    dates = DateTimeRange(
        start: DateTime(today.year, today.month, today.day - 6),
        end: DateTime(today.year, today.month, today.day));
    widget.accessChanges?.addListener(accessChanged);
    if (foreground) loadOptions();
  }

  @override
  void dispose() {
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    closeOwnedDialog();
    widget.accessChanges?.removeListener(accessChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    generation++;
    closeOwnedDialog();
    if (!mounted) return;
    setState(() {
      report = null;
      applied = null;
      targets = null;
      scopes = const [UsageReportScope.devices()];
      scope = const UsageReportScope.devices();
      selected.clear();
      error = null;
      optionsError = null;
      categoryFilter = 'ALL';
      loading = false;
    });
    if (current) loadOptions();
  }

  void accessChanged() {
    if (!widget.repository.current() && mounted) {
      closeOwnedDialog();
      setState(() {
        generation++;
        invalidated = true;
        report = null;
        targets = null;
        error = null;
      });
    }
  }

  void closeOwnedDialog() {
    final route = activeDialog;
    activeDialog = null;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) {
        route.navigator!.removeRoute(route);
      }
    });
  }

  Future<void> loadOptions() async {
    if (!current) return;
    final revision = ++generation;
    setState(() {
      optionsError = null;
      targets = null;
      report = null;
      applied = null;
      error = null;
    });
    try {
      widget.repository.ensureCurrent();
      final values = await Future.wait<Object>([
        widget.loadTargets(),
        widget.loadScopes?.call() ?? Future.value(<UsageReportScope>[])
      ]);
      final result = values[0] as List<UsageReportTarget>,
          loadedScopes = values[1] as List<UsageReportScope>;
      if (result.any((target) => !target.valid) ||
          result.map((target) => target.deviceId).toSet().length !=
              result.length ||
          loadedScopes.map((s) => s.key).toSet().length !=
              loadedScopes.length ||
          loadedScopes.any((s) => s.kind == 'DEVICES')) {
        throw const ApiFailure(502, 'INVALID_USAGE_REPORT_RESPONSE');
      }
      widget.repository.ensureCurrent();
      if (mounted && revision == generation) {
        setState(() {
          targets = List.unmodifiable(result);
          scopes = [const UsageReportScope.devices(), ...loadedScopes];
          scope = scopes.first;
          selected.clear();
          if (result.isNotEmpty) selected.add(result.first.deviceId);
        });
      }
    } catch (e) {
      if (mounted && revision == generation) setState(() => optionsError = e);
    }
  }

  Future<void> chooseScope(String key) async {
    if (!current) return;
    final choice = scopes.firstWhere((s) => s.key == key),
        revision = ++generation;
    setState(() {
      scope = choice;
      selected.clear();
      loading = true;
      report = null;
      error = null;
      applied = null;
    });
    try {
      widget.repository.ensureCurrent();
      final resolved =
          choice.kind == 'CLASS' ? await widget.resolveScope!(choice) : choice;
      widget.repository.ensureCurrent();
      if (resolved.key != choice.key || resolved.version != choice.version) {
        throw const ApiFailure(409, 'REPORT_SCOPE_CHANGED');
      }
      if (mounted && revision == generation) {
        setState(() {
          scope = resolved;
          if (available.length <= maxDevices) {
            selected.addAll(available.map((t) => t.deviceId));
          }
        });
      }
    } catch (e) {
      if (mounted && revision == generation) setState(() => error = e);
    } finally {
      if (mounted && revision == generation) setState(() => loading = false);
    }
  }

  Future<void> run({bool retry = false}) async {
    if (!current || loading) return;
    UsageReportQuery query;
    try {
      widget.repository.ensureCurrent();
      final window = usageCalendarWindow(dates.start, dates.end, zone);
      query = retry && applied != null
          ? applied!
          : UsageReportQuery(
              targets:
                  targets!.where((t) => selected.contains(t.deviceId)).toList(),
              from: window.$1,
              to: window.$2,
              timeZone: zone,
              period: period,
              scope: scope);
    } catch (e) {
      setState(() {
        error = e;
        report = null;
        applied = null;
      });
      return;
    }
    final revision = ++generation;
    setState(() {
      loading = true;
      error = null;
      report = null;
      applied = query;
    });
    try {
      final result = await widget.repository.load(query);
      if (mounted && revision == generation) {
        setState(() {
          report = result;
          categoryFilter = 'ALL';
        });
      }
    } catch (e) {
      if (mounted && revision == generation) setState(() => error = e);
    } finally {
      if (mounted && revision == generation) setState(() => loading = false);
    }
  }

  Future<void> chooseDevices() async {
    if (!current) return;
    final revision = generation;
    final result = await showDialog<Set<String>>(
        context: context,
        builder: (context) {
          activeDialog = ModalRoute.of(context);
          return UsageReportDevicePicker(
              targets: available, selected: selected, limit: maxDevices);
        });
    activeDialog = null;
    if (result != null && current && revision == generation) {
      setState(() {
        selected.clear();
        selected.addAll(result);
      });
    }
  }

  void background() {
    if (!current || loading || widget.onBackground == null) return;
    try {
      widget.repository.ensureCurrent();
      final chosen =
          available.where((t) => selected.contains(t.deviceId)).toList();
      if (chosen.length != selected.length) {
        throw const ApiFailure(409, 'REPORT_SCOPE_CHANGED');
      }
      final window = usageCalendarWindow(dates.start, dates.end, zone);
      final draft = UsageReportJobDraft(
          deviceIds: chosen.map((t) => t.deviceId),
          from: window.$1,
          to: window.$2,
          timeZone: zone,
          period: period,
          scope: scope);
      widget.onBackground!(draft);
    } catch (e) {
      setState(() => error = e);
    }
  }

  Future<void> chooseDates() async {
    if (!current) return;
    final revision = generation;
    final local = usageLocalTime(DateTime.now().millisecondsSinceEpoch, zone);
    final today = DateTime(local.year, local.month, local.day);
    final value = await showDateRangePicker(
        context: context,
        builder: (context, child) {
          activeDialog = ModalRoute.of(context);
          return child!;
        },
        firstDate: today.subtract(const Duration(days: 90)),
        lastDate: today,
        initialDateRange: DateTimeRange(
            start: dates.start.isAfter(today) ? today : dates.start,
            end: dates.end.isAfter(today) ? today : dates.end),
        helpText: '选择报表日期（按 $zone）',
        saveText: '应用日期');
    activeDialog = null;
    if (value != null && current && revision == generation) {
      setState(() => dates = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!foreground) {
      return const Panel(child: EmptyView('报表已隐藏', '返回前台后将重新检查设备与权限。'));
    }
    if (invalidated || !widget.repository.current()) {
      return const Panel(child: EmptyView('工作空间或权限已变化', '已隐藏旧报表，请重新打开使用报表。'));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeading('使用报表', '查看已授权设备的日／周观察范围，了解数据来源与覆盖情况。',
          action: widget.onJobs == null
              ? null
              : OutlinedButton.icon(
                  onPressed: widget.onJobs,
                  icon: const Icon(Icons.history),
                  label: const Text('报表任务'))),
      const Notice(
          '数据来自设备自行报告的系统汇总，尚未经独立验证。多个应用或设备可能同时运行；这里的时长不代表儿童唯一在线时间，也不用于硬额度结算。'),
      const SizedBox(height: 20),
      if (optionsError != null)
        Panel(
            child: FailureView(optionsError!,
                retry: loadOptions, reauth: widget.reauth))
      else if (targets == null)
        const Center(child: CircularProgressIndicator())
      else if (targets!.isEmpty)
        const Panel(child: EmptyView('暂无可查询的设备', '请先绑定并激活设备。儿童账号只能查询关联到自己的设备。'))
      else ...[
        Panel(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              Text('查询范围', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              Wrap(
                  spacing: 12,
                  runSpacing: 14,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                        width: 220,
                        child: DropdownButtonFormField<String>(
                            key: const ValueKey('usage-report-scope'),
                            value: scope.key,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '报表范围'),
                            items: scopes
                                .map((s) => DropdownMenuItem(
                                    value: s.key,
                                    child: Text(s.label,
                                        overflow: TextOverflow.ellipsis)))
                                .toList(),
                            onChanged: loading
                                ? null
                                : (value) => chooseScope(value!))),
                    OutlinedButton.icon(
                        onPressed: loading ? null : chooseDevices,
                        icon: const Icon(Icons.devices_outlined),
                        label: Text('设备 · ${selected.length} 台')),
                    OutlinedButton.icon(
                        onPressed: loading ? null : chooseDates,
                        icon: const Icon(Icons.date_range_outlined),
                        label: Text(
                            '${DateFormat('MM-dd').format(dates.start)} 至 ${DateFormat('MM-dd').format(dates.end)}')),
                    SizedBox(
                        width: 200,
                        child: DropdownButtonFormField<String>(
                            value: zone,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '日期与分组时区'),
                            items: {
                              zone,
                              'Asia/Shanghai',
                              'UTC',
                              'Asia/Hong_Kong',
                              'Asia/Tokyo',
                              'Europe/London',
                              'America/New_York'
                            }
                                .map((z) => DropdownMenuItem(
                                    value: z,
                                    child: Text(z,
                                        overflow: TextOverflow.ellipsis)))
                                .toList(),
                            onChanged: loading
                                ? null
                                : (value) => setState(() => zone = value!))),
                    SizedBox(
                        width: 130,
                        child: DropdownButtonFormField<String>(
                            value: period,
                            decoration:
                                const InputDecoration(labelText: '汇总方式'),
                            items: const [
                              DropdownMenuItem(value: 'DAY', child: Text('按日')),
                              DropdownMenuItem(value: 'WEEK', child: Text('按周'))
                            ],
                            onChanged: loading
                                ? null
                                : (v) => setState(() => period = v!))),
                    FilledButton.icon(
                        onPressed:
                            loading || selected.isEmpty || selected.length > 20
                                ? null
                                : () => run(),
                        icon: const Icon(Icons.bar_chart_outlined),
                        label: Text(loading ? '正在生成…' : '生成报表')),
                    if (widget.onBackground != null)
                      OutlinedButton.icon(
                          onPressed:
                              loading || selected.isEmpty ? null : background,
                          icon: const Icon(Icons.cloud_queue),
                          label: const Text('后台生成')),
                  ]),
              const SizedBox(height: 14),
              Text(
                  '即时生成最多 20 台${widget.onBackground == null ? '' : '，后台生成最多 200 台'}，时间范围最多 32 天。当前日期只计算到生成时刻；周从星期一开始。',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 6),
              Text(
                  '范围内共 ${available.length} 台可查询设备；当前选中 ${selected.length} 台。结果仅包含已选设备。${selected.length > 20 ? '请使用后台生成。' : ''}',
                  style: Theme.of(context).textTheme.bodySmall),
              if (available.isEmpty && error == null && !loading)
                const Notice('当前儿童或班级范围内没有可查询的已激活设备，请选择其他范围或检查名册与设备绑定。'),
              Text(
                  '已选：${targets!.where((t) => selected.contains(t.deviceId)).take(5).map((t) => t.displayName).join('、')}${selected.length > 5 ? ' 等 ${selected.length} 台' : ''}',
                  style: Theme.of(context).textTheme.bodySmall),
              Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                      onPressed: loading ? null : loadOptions,
                      child: const Text('刷新设备与范围')))
            ])),
        const SizedBox(height: 20),
        if (loading)
          const LinearProgressIndicator()
        else if (error != null)
          Panel(
              child: FailureView(error!,
                  retry: applied == null ? null : () => run(retry: true),
                  reauth: widget.reauth))
        else if (report != null) ...[
          SizedBox(
              width: 280,
              child: DropdownButtonFormField<String>(
                  key: const Key('usage-report-category'),
                  value: categoryFilter,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '结果内应用类别'),
                  items: [
                    const DropdownMenuItem(value: 'ALL', child: Text('全部类别')),
                    for (final entry in applicationCategories.entries)
                      DropdownMenuItem(
                          value: entry.key, child: Text(entry.value))
                  ],
                  onChanged: (value) =>
                      setState(() => categoryFilter = value!))),
          const SizedBox(height: 8),
          const Text(
              '按本次报表返回的当前分类筛选，不重新查询。分类由工作空间管理员声明，不代表历史分类或安全评级；设备覆盖率仍针对完整查询范围。'),
          const SizedBox(height: 14),
          Text(
              '报表范围：${report!.scope.label} · ${report!.scope.kind == 'CLASS' ? '名册版本 ${report!.scope.version} · ' : ''}仅含已选设备',
              style: Theme.of(context).textTheme.bodySmall),
          Text(
              '已应用：${usageTimestamp(report!.from, report!.timeZone)} 至 ${usageTimestamp(report!.to, report!.timeZone)} · ${report!.timeZone} · ${report!.period == 'DAY' ? '按日' : '按周'}',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          Text(
              '生成于 ${usageTimestamp(report!.generatedAt, report!.timeZone)} · ${report!.devices.length} 台设备',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 14),
          for (final device in report!.devices)
            Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: UsageReportDeviceView(
                    key: ValueKey(
                        '${report!.generatedAt}-${device.deviceId}-$categoryFilter'),
                    device: device,
                    categoryFilter: categoryFilter,
                    report: report!)),
        ] else
          const Panel(
              child: EmptyView('选择范围，生成使用报表', '不会自动开启设备的观察权限。缺失记录会明确标为未知。'))
      ]
    ]);
  }
}

class UsageReportDeviceView extends StatefulWidget {
  final UsageReportDevice device;
  final UsageReport report;
  final String categoryFilter;
  final bool historical;
  const UsageReportDeviceView(
      {super.key,
      required this.device,
      required this.report,
      this.historical = false,
      required this.categoryFilter});
  @override
  State<UsageReportDeviceView> createState() => UsageReportDeviceViewState();
}

class UsageReportDeviceViewState extends State<UsageReportDeviceView> {
  int selected = 0;
  @override
  Widget build(BuildContext context) {
    final d = widget.device,
        r = widget.report,
        apps = d.applications
            .where((app) =>
                widget.categoryFilter == 'ALL' ||
                app.classification.category == widget.categoryFilter)
            .toList(),
        app = apps.isEmpty ? null : apps[selected];
    return Panel(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(d.displayName, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 6),
      Text(
          '设备 ${d.deviceId.substring(0, 8)} · 当前显示 ${apps.length} / ${d.applications.length} 个应用资料组合',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 14),
      ReportConfigurationsView(
          state: d.configurationState,
          timeZone: r.timeZone,
          historical: widget.historical),
      const SizedBox(height: 14),
      if (d.status == 'NOT_AUTHORIZED')
        const EmptyView('尚未授权使用观察', '需要有权限的监护人或机构管理员在设备详情中明确授权。')
      else if (d.status == 'NO_DATA')
        const EmptyView(
            '暂无使用数据', '所选时段内没有保留的有效记录。这不代表使用量为零；请检查设备连接、系统观察权限和上传状态。')
      else ...[
        Wrap(spacing: 24, runSpacing: 12, children: [
          Text(
              '查询区间覆盖 ${(100 * d.queryCoverageMillis / (r.to - r.from)).toStringAsFixed(1)}%'),
          Text('来源 ${d.sourceBatchCount} 批'),
          Text('最近观测 ${usageTimestamp(d.latestObservedAt!, r.timeZone)}'),
          Text('最近接收 ${usageTimestamp(d.latestReceivedAt!, r.timeZone)}')
        ]),
        const SizedBox(height: 12),
        const Notice(
            '“查询区间覆盖”只说明设备查询过这些时间，不证明连续监测或所有应用都可见。范围上限包含缺失时段的可能使用量；区间重叠的旧记录会排除，避免重复计数。'),
        const SizedBox(height: 14),
        if (app == null)
          widget.categoryFilter != 'ALL' && d.applications.isNotEmpty
              ? const EmptyView('此类别下暂无应用记录', '可切换全部类别或未分类查看。这不代表此类别的使用量为零。')
              : const EmptyView(
                  '已收到记录，暂无应用明细', '设备提交的这些汇总不含可展示的应用区间，不代表所有应用均为零使用。')
        else ...[
          DropdownButtonFormField<int>(
              value: selected,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '应用与系统资料'),
              items: [
                for (int i = 0; i < apps.length; i++)
                  DropdownMenuItem(
                      value: i,
                      child: Text(
                          '${apps[i].displayName} · ${observationProfile(apps[i].profile)}',
                          overflow: TextOverflow.ellipsis))
              ],
              onChanged: (v) => setState(() => selected = v!)),
          const SizedBox(height: 8),
          Text(
              '类别：${applicationCategories[app.classification.category]} · ${app.classification.source == 'NONE' ? '尚未设置' : '来源：管理员声明 · 版本 ${app.classification.version}'}',
              style: Theme.of(context).textTheme.bodySmall),
          if (app.classification.updatedAt != null)
            Text(
                '分类更新于 ${usageTimestamp(app.classification.updatedAt!, r.timeZone)}',
                style: Theme.of(context).textTheme.bodySmall),
          SelectableText(app.packageName,
              style: Theme.of(context).textTheme.bodySmall),
          Text(
              '保留 ${app.selectedIntervals} 段证据 · 排除 ${app.discardedOverlaps} 段重叠记录',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 14),
          UsageTrendView(
              key: ValueKey('${app.profile}-${app.packageName}'),
              buckets: app.buckets,
              timeZone: r.timeZone,
              period: r.period),
          const SizedBox(height: 14),
          for (final bucket in app.buckets)
            Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          '${usageTimestamp(bucket.start, r.timeZone)} — ${usageTimestamp(bucket.end, r.timeZone)}',
                          style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 5),
                      Text(usageRange(bucket),
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 7),
                      if (bucket.lowerMillis != null)
                        Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  '应用区间证据覆盖 ${(100 * bucket.coveredMillis / (bucket.end - bucket.start)).toStringAsFixed(1)}%',
                                  style: Theme.of(context).textTheme.bodySmall),
                              const SizedBox(height: 5),
                              ExcludeSemantics(
                                  child: LinearProgressIndicator(
                                      value: bucket.coveredMillis /
                                          (bucket.end - bucket.start),
                                      minHeight: 5,
                                      backgroundColor: canvas))
                            ]),
                      const SizedBox(height: 5),
                      Text(
                          bucket.status == 'NO_EVIDENCE'
                              ? '此时段没有证据，不能按零计算'
                              : bucket.status == 'REPORTED_TOTAL'
                                  ? '汇总记录给出的时长，仍未经独立验证'
                                  : '可推导范围；不按比例推算精确用量',
                          style: Theme.of(context).textTheme.bodySmall)
                    ])),
        ]
      ],
      const SizedBox(height: 8),
      Text(
          '保留边界 ${usageTimestamp(d.retentionFrom, r.timeZone)} · 来源时区 ${d.sourceTimeZones.isEmpty ? '无' : d.sourceTimeZones.join('、')}',
          style: Theme.of(context).textTheme.bodySmall)
    ]));
  }
}
