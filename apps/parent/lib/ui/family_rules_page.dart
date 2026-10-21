import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../core/family.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import 'application_center.dart';
import 'family_workspace.dart';

class FamilyRulesPage extends StatefulWidget {
  final ParentSession session;
  final FamilyChild child;
  final Json? initialDraft;
  final int? initialDraftVersion;
  const FamilyRulesPage(
      {super.key,
      required this.session,
      required this.child,
      this.initialDraft,
      this.initialDraftVersion});
  @override
  State<FamilyRulesPage> createState() => _FamilyRulesPageState();
}

class _FamilyRulesPageState extends State<FamilyRulesPage> with FamilyScope {
  @override
  ParentSession get session => widget.session;
  FamilyRules? original, pending;
  String? operationKey;
  Object? error, appError;
  bool loading = true, saving = false, enabled = false;
  int allowance = 3600;
  final selectedPackages = <String>{};
  final windows = <FamilyWindow>[];
  List<Json> apps = [];
  String? appCursor;
  bool appLoading = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (!mounted || !current) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final rules = await service.rules(widget.child.id);
      if (!mounted || !current) return;
      final draft = widget.initialDraft;
      if (draft != null) {
        if (widget.initialDraftVersion == null ||
            rules.version != widget.initialDraftVersion) {
          throw const ParentApiException(409, 'RESOURCE_VERSION_CONFLICT');
        }
        final candidate = FamilyRules.fromJson({
          ...draft,
          'subjectId': rules.subjectId,
          'version': rules.version,
          'deliveryState': rules.deliveryState
        });
        setState(() => populate(candidate));
      } else {
        setState(() => populate(rules));
      }
      original = rules;
      await loadApps(reset: true);
    } catch (e) {
      if (current) setState(() => error = e);
    } finally {
      if (current) setState(() => loading = false);
    }
  }

  void populate(FamilyRules rules) {
    original = rules;
    enabled = rules.enabled;
    allowance = rules.dailyAllowanceSeconds;
    selectedPackages
      ..clear()
      ..addAll(rules.meteredPackages);
    windows
      ..clear()
      ..addAll(rules.allowedWindows);
  }

  Future<void> loadApps({bool reset = false}) async {
    if (!current || appLoading) return;
    setState(() {
      appLoading = true;
      appError = null;
      if (reset) {
        apps = [];
        appCursor = null;
      }
    });
    try {
      final page = await session.api.page('${service.root}/applications',
          cursor: appCursor, isCurrent: () => current);
      if (!mounted || !current) return;
      if (page.items.any((a) =>
          a['id'] is! String ||
          a['displayName'] is! String ||
          a['packageName'] is! String ||
          a['platform'] is! String)) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      setState(() {
        apps = [...apps, ...page.items];
        appCursor = page.nextCursor;
      });
    } catch (e) {
      if (current) setState(() => appError = e);
    } finally {
      if (current) setState(() => appLoading = false);
    }
  }

  Future<void> editWindow([int? index]) async {
    if (saving || pending != null || !current) return;
    final previous = index == null ? null : windows[index];
    final result = await showDialog<FamilyWindow>(
        context: context, builder: (_) => _WindowDialog(previous: previous));
    if (result != null && current) {
      setState(() {
        if (index == null) {
          windows.add(result);
        } else {
          windows[index] = result;
        }
      });
    }
  }

  Future<void> save() async {
    if (!current || saving || original == null) return;
    if (pending == null) {
      if (enabled && selectedPackages.isEmpty) {
        setState(() => error =
            const ParentApiException(400, 'FAMILY_APPLICATION_REQUIRED'));
        return;
      }
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('核对这份家庭约定'),
                  scrollable: true,
                  content: Text(
                      '${widget.child.nickname}\n${enabled ? '启用辅助限制' : '暂停辅助限制'}\n${allowance == 86400 ? '不设每日上限' : '每日所选应用 ${allowance ~/ 60} 分钟'}\n${selectedPackages.length} 个应用 · ${windows.length} 个可用时段\n\n保存后会向已连接设备发送配置；实际限制取决于儿童设备的权限与运行状态。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('继续调整')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('确认并保存'))
                  ]));
      if (confirmed != true || !current) return;
      pending = FamilyRules(
          subjectId: widget.child.id,
          version: original!.version,
          enabled: enabled,
          dailyAllowanceSeconds: allowance,
          timeZoneId: 'Asia/Shanghai',
          meteredPackages: selectedPackages.toList(),
          allowedWindows: List.of(windows),
          deliveryState: original!.deliveryState);
      operationKey = const Uuid().v4();
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final saved = await service.saveRules(widget.child.id, pending!,
          idempotencyKey: operationKey!);
      if (!mounted || !current) return;
      setState(() {
        populate(saved);
        pending = null;
        operationKey = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('家庭规则已保存，请在设备上核对辅助运行状态。')));
    } catch (e) {
      if (current) {
        setState(() {
          error = e;
          // Definite rejection did not mutate. Unknown outcomes retain exact body/key.
          if (e is ParentApiException &&
              e.status >= 400 &&
              e.status < 500 &&
              e.status != 408 &&
              e.code != 'IDEMPOTENCY_IN_PROGRESS') {
            pending = null;
            operationKey = null;
          }
        });
      }
    } finally {
      if (current) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = saving || pending != null;
    final options = {0, 1800, 3600, 5400, 7200, 10800, 14400, 86400, allowance}
        .toList()
      ..sort();
    final known = apps
        .where((a) => a['platform'] == 'ANDROID')
        .fold<Map<String, Json>>(
            {}, (map, a) => map..putIfAbsent(a['packageName'], () => a));
    return Scaffold(
        appBar: AppBar(title: Text('${widget.child.nickname}的规则')),
        body: !current
            ? const Center(child: Text('当前家庭或权限已变化，请返回重新打开。'))
            : loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(padding: const EdgeInsets.all(20), children: [
                    if (widget.initialDraft != null)
                      const FamilyNotice('这是助手整理的草稿，尚未保存。请逐项核对后由你确认。'),
                    if (error != null)
                      FamilyNotice(familyError(error!), error: true),
                    if (original == null)
                      OutlinedButton(
                          onPressed: load, child: const Text('重新读取规则')),
                    if (original != null) ...[
                      FamilyPanel(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('辅助限制'),
                                subtitle: const Text('在儿童设备权限允许时提供提醒与辅助限制'),
                                value: enabled,
                                onChanged: locked
                                    ? null
                                    : (v) => setState(() => enabled = v)),
                            const SizedBox(height: 16),
                            DropdownButtonFormField<int>(
                                value: allowance,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                    labelText: '每日所选应用用时'),
                                items: options
                                    .map((n) => DropdownMenuItem(
                                        value: n,
                                        child: Text(n == 86400
                                            ? '不设每日上限'
                                            : n == 0
                                                ? '暂停使用所选应用'
                                                : '${n ~/ 60} 分钟')))
                                    .toList(),
                                onChanged: locked
                                    ? null
                                    : (value) {
                                        if (value != null) {
                                          setState(() => allowance = value);
                                        }
                                      }),
                            const SizedBox(height: 12),
                            const Text('按中国标准时间（Asia/Shanghai）计算。只对下方选中的应用计时。',
                                style: TextStyle(color: familyMuted)),
                          ])),
                      FamilyPanel(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            const Text('选择应用',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 8),
                            const Text('仅显示本家庭已登记的 Android 应用。紧急联系和系统安全应用不能限制。',
                                style: TextStyle(color: familyMuted)),
                            if (appError != null)
                              FamilyNotice(familyError(appError!), error: true),
                            if (appLoading) const LinearProgressIndicator(),
                            for (final entry in known.entries)
                              CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  title: Text(entry.value['displayName']),
                                  value: selectedPackages.contains(entry.key),
                                  onChanged: locked
                                      ? null
                                      : (v) => setState(() {
                                            if (v == true) {
                                              selectedPackages.add(entry.key);
                                            } else {
                                              selectedPackages
                                                  .remove(entry.key);
                                            }
                                          })),
                            for (final pkg in selectedPackages
                                .where((p) => !known.containsKey(p)))
                              CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('已选应用（名称待核对）'),
                                  subtitle: Text(pkg),
                                  value: true,
                                  onChanged: locked
                                      ? null
                                      : (_) => setState(
                                          () => selectedPackages.remove(pkg))),
                            if (known.isEmpty && !appLoading)
                              const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                  child: Text('还没有可选应用，请先在应用目录中登记。')),
                            if (appCursor != null)
                              TextButton(
                                  onPressed:
                                      appLoading || locked ? null : loadApps,
                                  child: const Text('加载更多应用')),
                            Wrap(spacing: 8, children: [
                              TextButton(
                                  onPressed: locked || appLoading
                                      ? null
                                      : () => loadApps(reset: true),
                                  child: const Text('刷新应用')),
                              TextButton(
                                  onPressed: locked
                                      ? null
                                      : () async {
                                          await Navigator.of(context).push(
                                              MaterialPageRoute(
                                                  builder: (_) =>
                                                      ApplicationCenter(
                                                          session: session)));
                                          if (current) {
                                            await loadApps(reset: true);
                                          }
                                        },
                                  child: const Text('管理应用目录')),
                            ]),
                          ])),
                      FamilyPanel(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            const Text('可用时段',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 8),
                            const Text('未添加时段表示全天可用，仍受每日额度限制。跨夜安排会延续到次日。',
                                style: TextStyle(color: familyMuted)),
                            for (var i = 0; i < windows.length; i++)
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                            '${windows[i].days.map((d) => _days[d - 1]).join('、')}\n${_clock(windows[i].startMinute)}–${_clock(windows[i].endMinute)}'),
                                        Wrap(children: [
                                          TextButton(
                                              onPressed: locked
                                                  ? null
                                                  : () => editWindow(i),
                                              child: const Text('调整')),
                                          TextButton(
                                              onPressed: locked
                                                  ? null
                                                  : () => setState(() =>
                                                      windows.removeAt(i)),
                                              child: const Text('移除'))
                                        ]),
                                      ])),
                            if (windows.length < 14)
                              OutlinedButton.icon(
                                  onPressed: locked ? null : editWindow,
                                  icon: const Icon(Icons.add),
                                  label: const Text('添加可用时段')),
                          ])),
                      const FamilyNotice(
                          '这是家庭辅助限制，不提供系统强制或防卸载保证。保存成功表示配置已记录，仍须核对设备状态。'),
                      if (pending != null)
                        const FamilyNotice('上次保存结果待核对。重试会使用原内容和请求编号，不会创建新操作。'),
                      FilledButton.icon(
                          onPressed: saving ? null : save,
                          icon: saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.check),
                          label: Text(saving
                              ? '正在保存…'
                              : pending == null
                                  ? '核对并保存规则'
                                  : '重试原保存')),
                      if (error is ParentApiException &&
                          (error as ParentApiException).code ==
                              'RESOURCE_VERSION_CONFLICT')
                        TextButton(
                            onPressed: loading || saving ? null : load,
                            child: const Text('读取最新规则后重新核对')),
                    ],
                  ]));
  }
}

const _days = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
String _clock(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

class _WindowDialog extends StatefulWidget {
  final FamilyWindow? previous;
  const _WindowDialog({this.previous});
  @override
  State<_WindowDialog> createState() => _WindowDialogState();
}

class _WindowDialogState extends State<_WindowDialog> {
  late Set<int> days;
  late int start, end;
  String? error;
  @override
  void initState() {
    super.initState();
    days = (widget.previous?.days ?? [1, 2, 3, 4, 5]).toSet();
    start = widget.previous?.startMinute ?? 1080;
    end = widget.previous?.endMinute ?? 1200;
  }

  Future<void> choose(bool first) async {
    final value = first ? start : end;
    final picked = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: value ~/ 60, minute: value % 60),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
            child: child!));
    if (picked != null && mounted) {
      setState(() {
        if (first) {
          start = picked.hour * 60 + picked.minute;
        } else {
          end = picked.hour * 60 + picked.minute;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('安排可用时段'),
          scrollable: true,
          content:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (var d = 1; d <= 7; d++)
                FilterChip(
                    label: Text(_days[d - 1]),
                    selected: days.contains(d),
                    onSelected: (v) => setState(() {
                          if (v) {
                            days.add(d);
                          } else {
                            days.remove(d);
                          }
                        }))
            ]),
            const SizedBox(height: 16),
            OutlinedButton(
                onPressed: () => choose(true),
                child: Text('开始 ${_clock(start)}')),
            const SizedBox(height: 8),
            OutlinedButton(
                onPressed: () => choose(false),
                child: Text('结束 ${_clock(end)}')),
            if (end < start) const Text('此安排跨夜，到次日结束。'),
            if (error != null) FamilyNotice(error!, error: true),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: () {
                  if (days.isEmpty || start == end) {
                    setState(() => error = '请选择日期，开始和结束时间不能相同。');
                    return;
                  }
                  Navigator.pop(
                      context, FamilyWindow(days.toList()..sort(), start, end));
                },
                child: const Text('确认时段'))
          ]);
}
