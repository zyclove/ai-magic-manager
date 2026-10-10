import 'dart:async';
import 'package:flutter/material.dart';
import 'package:usage_reporting/usage_reporting.dart';
import 'design.dart';
import 'usage_trend_view.dart';
import 'report_configurations_view.dart';

class DeviceReportWindow {
  final int from, to;
  final String timeZone, period;
  const DeviceReportWindow(this.from, this.to, this.timeZone, this.period);
}

/// Place in the host's scroll view. The host supplies an authenticated, typed
/// loader and cancels its owned network work when requested. No data is stored.
class DeviceUsageReportView extends StatefulWidget {
  final Future<UsageReport> Function(DeviceReportWindow) load;
  final VoidCallback cancel;
  final Listenable accessChanges;
  final bool Function() available;
  final VoidCallback? reconnect;
  final String timeZone;
  final DateTime Function()? now;
  const DeviceUsageReportView(
      {super.key,
      required this.load,
      required this.cancel,
      required this.accessChanges,
      required this.available,
      this.reconnect,
      this.timeZone = 'Asia/Shanghai',
      this.now});
  @override
  State<DeviceUsageReportView> createState() => _DeviceUsageReportViewState();
}

class _DeviceUsageReportViewState extends State<DeviceUsageReportView>
    with WidgetsBindingObserver {
  late String _zone;
  late DateTimeRange _dates;
  String _period = 'DAY', _category = 'ALL';
  int _generation = 0, _selected = 0;
  int? _quickDays = 7;
  bool _loading = false, _foreground = true;
  UsageReport? _report;
  Object? _error;
  DeviceReportWindow? _applied;
  ModalRoute<dynamic>? _dialog;
  bool get _available => _foreground && widget.available();
  DateTime get _today {
    final local = usageLocalTime(
        (widget.now?.call() ?? DateTime.now()).millisecondsSinceEpoch, _zone);
    return DateTime(local.year, local.month, local.day);
  }

  @override
  void initState() {
    super.initState();
    _zone = widget.timeZone;
    try {
      usageLocation(_zone);
    } on UsageReportFailure {
      _zone = 'UTC';
    }
    _dates = DateTimeRange(
        start: _today.subtract(const Duration(days: 6)), end: _today);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    widget.accessChanges.addListener(_accessChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _available) unawaited(_run());
    });
  }

  void _closeDialog() {
    final route = _dialog;
    _dialog = null;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final navigator = route.navigator;
        if (route.isActive && navigator != null && navigator.mounted) {
          navigator.removeRoute(route);
        }
      });
    }
  }

  void _clear({bool closeDialog = false}) {
    _generation++;
    _report = null;
    _error = null;
    _applied = null;
    _loading = false;
    _category = 'ALL';
    _selected = 0;
    try {
      widget.cancel();
    } catch (_) {/* Invalidated results stay hidden. */}
    if (closeDialog) _closeDialog();
  }

  void _accessChanged() {
    if (!mounted) return;
    setState(() {
      if (!_available) _clear(closeDialog: true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _accessChanged();
  }

  @override
  void didUpdateWidget(covariant DeviceUsageReportView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accessChanges != widget.accessChanges) {
      oldWidget.accessChanges.removeListener(_accessChanged);
      widget.accessChanges.addListener(_accessChanged);
      _clear(closeDialog: true);
    } else if (!_available) {
      _clear(closeDialog: true);
    }
  }

  @override
  void dispose() {
    widget.accessChanges.removeListener(_accessChanged);
    WidgetsBinding.instance.removeObserver(this);
    _clear(closeDialog: true);
    super.dispose();
  }

  Future<void> _run({bool retry = false}) async {
    if (!_available || _loading) return;
    final bounds = usageCalendarWindow(_dates.start, _dates.end, _zone);
    final window = retry && _applied != null
        ? _applied!
        : DeviceReportWindow(bounds.$1, bounds.$2, _zone, _period);
    final revision = ++_generation;
    setState(() {
      _report = null;
      _error = null;
      _loading = true;
      _applied = window;
    });
    try {
      final value = await widget.load(window);
      if (!mounted || revision != _generation || !_available) return;
      if (value.devices.length != 1 ||
          value.scope.kind != 'DEVICES' ||
          value.from != window.from ||
          value.to > window.to ||
          value.period != window.period ||
          value.timeZone != window.timeZone) {
        throw const UsageReportFailure(502, 'INVALID_USAGE_REPORT_RESPONSE');
      }
      setState(() {
        _report = value;
        _category = 'ALL';
        _selected = 0;
      });
    } catch (error) {
      if (mounted && revision == _generation && _available) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && revision == _generation) setState(() => _loading = false);
    }
  }

  void _edit(VoidCallback change) => setState(() {
        _clear();
        change();
      });
  Future<void> _chooseDates() async {
    final revision = _generation, today = _today;
    final first = today.subtract(const Duration(days: 30));
    final selected = await showDialog<DateTimeRange>(
        context: context,
        builder: (context) {
          _dialog = ModalRoute.of(context);
          return DateRangePickerDialog(
              firstDate: first,
              lastDate: today,
              currentDate: today,
              initialDateRange:
                  _dates.start.isBefore(first) || _dates.end.isAfter(today)
                      ? null
                      : _dates,
              helpText: '选择报表日期',
              saveText: '使用这些日期');
        });
    _dialog = null;
    if (mounted && _available && revision == _generation && selected != null) {
      _edit(() {
        _dates = selected;
        _quickDays = null;
      });
    }
  }

  Future<void> _chooseZone() async {
    final revision = _generation,
        controller = TextEditingController(text: _zone);
    String? error;
    final selected = await showDialog<String>(
        context: context,
        builder: (context) {
          _dialog = ModalRoute.of(context);
          return StatefulBuilder(
              builder: (context, update) => AlertDialog(
                      title: const Text('报表时区'),
                      content: SizedBox(
                          width: 400,
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TextField(
                                    key: const Key('report-zone-input'),
                                    controller: controller,
                                    maxLength: 100,
                                    autocorrect: false,
                                    decoration: InputDecoration(
                                        labelText: 'IANA 时区',
                                        errorText: error)),
                                const SizedBox(height: 12),
                                Wrap(spacing: 8, children: [
                                  for (final zone in [
                                    'Asia/Shanghai',
                                    'UTC',
                                    'Asia/Tokyo'
                                  ])
                                    ActionChip(
                                        label: Text(zone),
                                        onPressed: () => controller.text = zone)
                                ]),
                                const Text('日期按所选时区分组。修改后请重新查看报表。'),
                              ])),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('取消')),
                        FilledButton(
                            onPressed: () {
                              final zone = controller.text.trim();
                              try {
                                usageLocation(zone);
                                Navigator.pop(context, zone);
                              } on UsageReportFailure {
                                update(() => error = '请输入有效的 IANA 时区');
                              }
                            },
                            child: const Text('使用此时区'))
                      ]));
        });
    controller.dispose();
    _dialog = null;
    if (mounted && _available && revision == _generation && selected != null) {
      _edit(() => _zone = selected);
    }
  }

  Future<void> _chooseApplication(List<UsageReportApplication> apps) async {
    final revision = _generation;
    var search = '';
    final selected = await showDialog<int>(
        context: context,
        builder: (context) {
          _dialog = ModalRoute.of(context);
          return StatefulBuilder(builder: (context, update) {
            final matches = [
              for (var i = 0; i < apps.length; i++)
                if ('${apps[i].displayName} ${apps[i].packageName}'
                    .toLowerCase()
                    .contains(search))
                  i
            ];
            return AlertDialog(
                title: const Text('选择应用'),
                content: SizedBox(
                    width: 440,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          decoration: const InputDecoration(
                              labelText: '搜索名称或包名',
                              prefixIcon: Icon(Icons.search)),
                          onChanged: (v) =>
                              update(() => search = v.trim().toLowerCase())),
                      const SizedBox(height: 12),
                      SizedBox(
                          height: 300,
                          child: matches.isEmpty
                              ? const Center(child: Text('没有匹配的应用'))
                              : ListView.builder(
                                  itemCount: matches.length,
                                  itemBuilder: (context, index) {
                                    final position = matches[index],
                                        app = apps[position];
                                    return RadioListTile<int>(
                                        value: position,
                                        groupValue: _selected,
                                        title: Text(app.displayName),
                                        subtitle: Text(
                                            '${label(app.profile)} · ${app.packageName}'),
                                        onChanged: (value) =>
                                            Navigator.pop(context, value));
                                  }))
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'))
                ]);
          });
        });
    _dialog = null;
    if (mounted && _available && revision == _generation && selected != null) {
      setState(() => _selected = selected);
    }
  }

  String get _errorMessage {
    final code =
        _error is UsageReportFailure ? (_error as UsageReportFailure).code : '';
    return switch (code) {
      'REPORT_NOT_AVAILABLE' => '当前服务版本尚未提供本设备报表，请联系监护人检查服务更新。',
      'DEVICE_LOCKED' || 'OBSERVATION_DEVICE_LOCKED' => '请先解锁设备，再重新读取报表。',
      'SCOPE_DENIED' ||
      'DEVICE_UNAUTHENTICATED' ||
      'DEVICE_CREDENTIAL_REVOKED' ||
      'DEVICE_CREDENTIAL_UNAVAILABLE' ||
      'DEVICE_CONTEXT_CHANGED' ||
      'ACCESS_TARGET_CHANGED' =>
        '设备连接或访问权限已变化。请回到设备页检查连接，再重新打开报表。',
      'USAGE_REPORT_TOO_LARGE' => '报表数据较多，请缩短日期范围后重新查看。',
      'INVALID_USAGE_REPORT_RESPONSE' ||
      'RESPONSE_INVALID' ||
      'INVALID_CLASSIFICATION_RESPONSE' =>
        '数据校验未通过，已隐藏结果。请重新读取，或请监护人检查设备状态。',
      'INVALID_TIME_ZONE' => '此时区暂不可用，请选择有效时区后重新查看。',
      'REPORT_SCOPE_CHANGED' => '设备所属档案已变化，请重新打开报表。',
      _ => '暂时无法连接报表服务，请检查网络后按原条件重试。',
    };
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _available && !_loading;
    final report = _report;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(
          header: true,
          child: Text('我的使用情况',
              style: Theme.of(context).textTheme.headlineMedium)),
      const SizedBox(height: 12),
      const Text('查看这台设备的使用记录，了解自己的使用习惯。'),
      const SizedBox(height: 20),
      if (!_available) ...[
        const _Info('报表暂不可用', '请先确认设备连接，并在应用前台查看。'),
        if (widget.reconnect != null)
          TextButton(onPressed: widget.reconnect, child: const Text('检查设备连接')),
      ] else ...[
        SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'DAY', label: Text('日')),
              ButtonSegment(value: 'WEEK', label: Text('周'))
            ],
            selected: {
              _period
            },
            onSelectionChanged:
                enabled ? (v) => _edit(() => _period = v.single) : null),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final days in [7, 14, 30])
            ChoiceChip(
                label: Text('近 $days 天'),
                selected: _quickDays == days,
                onSelected: enabled
                    ? (_) => _edit(() {
                          _quickDays = days;
                          _dates = DateTimeRange(
                              start: _today.subtract(Duration(days: days - 1)),
                              end: _today);
                        })
                    : null)
        ]),
        const SizedBox(height: 8),
        OutlinedButton.icon(
            key: const Key('report-dates'),
            onPressed: enabled ? _chooseDates : null,
            icon: const Icon(Icons.date_range),
            label: Text('${_date(_dates.start)} 至 ${_date(_dates.end)}')),
        OutlinedButton.icon(
            key: const Key('report-timezone'),
            onPressed: enabled ? _chooseZone : null,
            icon: const Icon(Icons.public),
            label: Text('时区：$_zone')),
        const SizedBox(height: 12),
        FilledButton.icon(
            key: const Key('report-query'),
            onPressed: enabled ? () => _run() : null,
            icon: const Icon(Icons.refresh),
            label: Text(report == null ? '查看报表' : '更新报表')),
        const SizedBox(height: 20),
        if (_loading) ...[
          const LinearProgressIndicator(semanticsLabel: '正在读取使用报表'),
          TextButton(
              onPressed: () => setState(() => _clear()),
              child: const Text('取消加载')),
        ] else if (_error != null) ...[
          Semantics(liveRegion: true, child: _Info('未能读取报表', _errorMessage)),
          TextButton.icon(
              key: const Key('report-retry'),
              onPressed: () => _run(retry: true),
              icon: const Icon(Icons.refresh),
              label: const Text('按原条件重试')),
          if (widget.reconnect != null)
            TextButton(
                onPressed: widget.reconnect, child: const Text('检查设备连接')),
        ] else if (report != null)
          ..._result(context, report)
        else
          const _Info('尚未读取当前条件', '点击“查看报表”读取最新数据。'),
      ],
    ]);
  }

  List<Widget> _result(BuildContext context, UsageReport report) {
    final device = report.devices.single;
    final apps = device.applications
        .where(
            (a) => _category == 'ALL' || a.classification.category == _category)
        .toList();
    final app = apps.isEmpty ? null : apps[_selected.clamp(0, apps.length - 1)];
    return [
      Text('更新于 ${usageTimestamp(report.generatedAt, report.timeZone)}',
          style: Theme.of(context).textTheme.bodySmall),
      Text(
          '${usageTimestamp(report.from, report.timeZone)} 至 ${usageTimestamp(report.to, report.timeZone)} · ${report.timeZone}',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      const _Info('如何理解这些记录', '数据来自设备汇总，尚未经独立验证。未知时段不按零计算，多个应用的时长也不等于你的在线总时长。'),
      const SizedBox(height: 16),
      if (device.status == 'NO_DATA')
        const _Info('暂无使用记录', '这个时段还没有可展示的记录，不代表使用时长为零。')
      else if (device.status == 'NOT_AUTHORIZED')
        const _Info('使用观察尚未授权', '请与监护人确认使用观察设置；此处不会显示以前的用量。')
      else ...[
        Text(
            '查询区间覆盖 ${(100 * device.queryCoverageMillis / (report.to - report.from)).toStringAsFixed(1)}% · 来源 ${device.sourceBatchCount} 批',
            style: Theme.of(context).textTheme.bodySmall),
        const Text('覆盖率只表示查询过这些时间，不证明持续监测或所有应用均可见。'),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
            value: _category,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '应用类别'),
            items: [
              const DropdownMenuItem(value: 'ALL', child: Text('全部类别')),
              for (final entry in applicationCategories.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value))
            ],
            onChanged: (value) => setState(() {
                  _category = value!;
                  _selected = 0;
                })),
        const SizedBox(height: 12),
        if (app == null)
          _Info(
              device.applications.isEmpty ? '暂无应用明细' : '该类别暂无匹配应用',
              device.applications.isEmpty
                  ? '设备提交的汇总不包含可展示的应用区间。'
                  : '分类由监护人维护，可以选择其他类别。')
        else ...[
          Text('应用与系统资料', style: Theme.of(context).textTheme.titleSmall),
          OutlinedButton(
              onPressed: () => _chooseApplication(apps),
              child: Row(children: [
                Expanded(
                    child: Text('${app.displayName} · ${label(app.profile)}')),
                const Icon(Icons.expand_more)
              ])),
          Text(
              '类别：${applicationCategories[app.classification.category]} · ${app.classification.source == 'NONE' ? '尚未设置' : '管理员声明'}',
              style: Theme.of(context).textTheme.bodySmall),
          if (app.classification.updatedAt != null)
            Text(
                '分类更新于 ${usageTimestamp(app.classification.updatedAt!, report.timeZone)}',
                style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 14),
          UsageTrendView(
              key: ValueKey('$_generation/${app.profile}/${app.packageName}'),
              buckets: app.buckets,
              timeZone: report.timeZone,
              period: report.period),
          ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('查看时段明细与来源'),
              children: [
                for (final bucket in app.buckets)
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(usageRange(bucket)),
                      subtitle: Text(
                          '${usageTimestamp(bucket.start, report.timeZone)} 至 ${usageTimestamp(bucket.end, report.timeZone)}\n${bucket.lowerMillis == null ? '没有观测证据' : '应用区间证据覆盖 ${(100 * bucket.coveredMillis / (bucket.end - bucket.start)).toStringAsFixed(1)}%'}')),
                Text(
                    '保留 ${app.selectedIntervals} 段证据，排除 ${app.discardedOverlaps} 段重叠记录。'),
                SelectableText(app.packageName,
                    style: Theme.of(context).textTheme.bodySmall),
              ]),
        ],
      ],
      const SizedBox(height: 20),
      ReportConfigurationsView(
          state: device.configurationState, timeZone: report.timeZone),
      Text('保留边界 ${usageTimestamp(device.retentionFrom, report.timeZone)}',
          style: Theme.of(context).textTheme.bodySmall),
    ];
  }
}

String _date(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

class _Info extends StatelessWidget {
  final String title, detail;
  const _Info(this.title, this.detail);
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(16),
      decoration:
          BoxDecoration(color: canvas, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        Text(detail)
      ]));
}
