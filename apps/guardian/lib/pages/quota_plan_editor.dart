import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../core/api.dart';
import '../ui/design.dart';
import '../ui/quota_balance.dart';

const quotaWeek = <String, String>{
  'MONDAY': '周一',
  'TUESDAY': '周二',
  'WEDNESDAY': '周三',
  'THURSDAY': '周四',
  'FRIDAY': '周五',
  'SATURDAY': '周六',
  'SUNDAY': '周日'
};

/// Pure form: the caller supplies fixed workspace, version and idempotency context.
class QuotaPlanEditor extends StatefulWidget {
  final Map<String, String> children, applications;
  final Json? plan;
  final String? targetDescription;
  final Future<Json> Function(String subject) loadCalendar;
  final Future<void> Function(Json body) onSubmit;
  final VoidCallback? reauth;
  const QuotaPlanEditor(
      {super.key,
      required this.children,
      required this.applications,
      this.plan,
      this.targetDescription,
      required this.loadCalendar,
      required this.onSubmit,
      this.reauth});
  @override
  State<QuotaPlanEditor> createState() => _QuotaPlanEditorState();
}

class _QuotaPlanEditorState extends State<QuotaPlanEditor> {
  final form = GlobalKey<FormState>();
  final errorAnchor = GlobalKey();
  late final TextEditingController name;
  final days = <String, TextEditingController>{};
  final originalSeconds = <String, int>{};
  final changedDays = <String>{};
  final overrides = <String, int>{};
  String? subject;
  String application = '', state = 'ACTIVE';
  bool tomorrow = false, busy = false;
  int calendarGeneration = 0;
  Json? calendar, pending;
  Object? error;
  bool get locked => busy || pending != null;
  bool get editing => widget.plan != null;
  @override
  void initState() {
    super.initState();
    final p = widget.plan;
    name = TextEditingController(text: p?['name'] as String? ?? '每周使用额度');
    subject = p?['subjectId'] as String? ??
        (widget.children.length == 1 ? widget.children.keys.first : null);
    application = p?['applicationId'] as String? ?? '';
    state = p?['state'] as String? ?? 'ACTIVE';
    for (final day in quotaWeek.keys) {
      final seconds =
          ((p?['weeklyLimits'] as Map?)?[day] as num?)?.toInt() ?? 3600;
      originalSeconds[day] = seconds;
      days[day] = TextEditingController(text: (seconds ~/ 60).toString());
    }
    for (final entry in ((p?['dateOverrides'] as Map?) ?? {}).entries) {
      overrides[entry.key as String] = (entry.value as num).toInt();
    }
    if (subject != null) loadCalendar();
  }

  Future<void> loadCalendar() async {
    final selected = subject;
    if (selected == null) return;
    final generation = ++calendarGeneration;
    setState(() {
      calendar = null;
      error = null;
    });
    try {
      final value = await widget.loadCalendar(selected);
      if (mounted && generation == calendarGeneration) {
        setState(() => calendar = value);
      }
    } catch (e) {
      if (mounted && generation == calendarGeneration) {
        setState(() => error = e);
        revealError();
      }
    }
  }

  void revealError() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = errorAnchor.currentContext;
      if (mounted && target != null) {
        Scrollable.ensureVisible(target,
            alignment: 1,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut);
      }
    });
  }

  String get effectiveDate {
    final today = calendar?['currentDate'] as String?;
    if (today == null) return '读取日历中';
    final date = DateTime.parse(today);
    // Civil dates must not inherit the browser's 23/25-hour DST day.
    return DateFormat('yyyy-MM-dd').format(DateTime.utc(
        date.year, date.month, date.day + (editing || tomorrow ? 1 : 0)));
  }

  @override
  void dispose() {
    name.dispose();
    for (final c in days.values) {
      c.dispose();
    }
    super.dispose();
  }

  void copyDays(String source, Iterable<String> targets) {
    for (final day in targets) {
      days[day]!.text = days[source]!.text;
      changedDays.add(day);
    }
    setState(() {});
  }

  Future<void> addOverride() async {
    if (calendar == null || locked) return;
    if (overrides.length >= 60) {
      toast(context, '最多设置 60 个日期例外，请先删除不再需要的日期。');
      return;
    }
    final today = DateTime.parse(calendar!['currentDate']);
    final selected = await showDatePicker(
        context: context,
        initialDate: today,
        firstDate: today,
        lastDate: DateTime(today.year, today.month, today.day + 366),
        helpText: '选择单独设置额度的日期');
    if (selected == null || !mounted) return;
    final date = DateFormat('yyyy-MM-dd').format(selected);
    final result = await formDialog(context,
        title: '$date 的额度',
        description: '此日期使用这里的额度，覆盖星期规则。0 分钟表示该日无可分配时间。',
        fields: const [
          FieldSpec('minutes', '额度（分钟，0–1440）', numeric: true, maxLength: 4)
        ],
        initial: {
          'minutes': (overrides[date] ?? 3600) ~/ 60
        }, onSubmit: (value) async {
      final minutes = value['minutes'] as int;
      if (minutes > 1440) throw const ApiFailure(400, 'QUOTA_LIMIT_INVALID');
      return {'seconds': minutes * 60};
    });
    if (result != null && mounted) {
      setState(() => overrides[date] = result['seconds'] as int);
    }
  }

  Future<void> save() async {
    if (!form.currentState!.validate() || calendar == null || subject == null) {
      return;
    }
    final data = pending ??
        <String, dynamic>{
          'name': name.text.trim(),
          if (editing) 'state': state,
          if (!editing) ...{
            'subjectId': subject,
            'scope': application.isEmpty ? 'TOTAL' : 'APPLICATION',
            if (application.isNotEmpty) 'applicationId': application,
            'timeZone': calendar!['timeZone'],
            'effectiveFrom': effectiveDate,
          },
          'weeklyLimits': {
            for (final day in quotaWeek.keys)
              day: changedDays.contains(day)
                  ? int.parse(days[day]!.text) * 60
                  : originalSeconds[day]
          },
          'dateOverrides': Map<String, int>.from(overrides),
        };
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onSubmit(data);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e;
          if (e is! ApiFailure || e.status == 0 || e.status >= 500) {
            pending = data;
          }
        });
        revealError();
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: Text(editing ? '修改重复计划' : '创建重复计划'),
        content: SizedBox(
            width: 680,
            child: SingleChildScrollView(
                child: Form(
                    key: form,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (editing && widget.targetDescription != null)
                            Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Text(widget.targetDescription!,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        height: 1.6))),
                          Notice(editing
                              ? '修改从下方生效日开始；今天的余额、已用量和预留保持原样。'
                              : '每天自动生成一份额度。已有的每日额度保留，计划不会覆盖当天手工调整。'),
                          const SizedBox(height: 20),
                          TextFormField(
                              controller: name,
                              enabled: !locked,
                              decoration:
                                  const InputDecoration(labelText: '计划名称'),
                              maxLength: 100,
                              validator: (v) =>
                                  (v ?? '').trim().isEmpty ? '请输入计划名称' : null),
                          if (!editing) ...[
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                                value: subject,
                                isExpanded: true,
                                decoration:
                                    const InputDecoration(labelText: '儿童'),
                                items: [
                                  for (final child in widget.children.entries)
                                    DropdownMenuItem(
                                        value: child.key,
                                        child: Text(child.value,
                                            overflow: TextOverflow.ellipsis))
                                ],
                                onChanged: locked
                                    ? null
                                    : (v) {
                                        setState(() => subject = v);
                                        loadCalendar();
                                      },
                                validator: (v) => v == null ? '请选择儿童' : null),
                            const SizedBox(height: 18),
                            DropdownButtonFormField<String>(
                                value: application,
                                isExpanded: true,
                                decoration:
                                    const InputDecoration(labelText: '额度范围'),
                                items: [
                                  const DropdownMenuItem(
                                      value: '', child: Text('儿童总额度')),
                                  ...widget.applications.entries.map((e) =>
                                      DropdownMenuItem(
                                          value: e.key,
                                          child: Text(e.value,
                                              overflow: TextOverflow.ellipsis)))
                                ],
                                onChanged: locked
                                    ? null
                                    : (v) =>
                                        setState(() => application = v ?? '')),
                            CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('从明天开始'),
                                value: tomorrow,
                                onChanged: locked
                                    ? null
                                    : (v) =>
                                        setState(() => tomorrow = v ?? false)),
                          ],
                          const SizedBox(height: 12),
                          Text(
                              '生效日：$effectiveDate  ·  时区：${calendar?['timeZone'] ?? '等待选择儿童'}',
                              style:
                                  const TextStyle(color: muted, height: 1.6)),
                          const SizedBox(height: 20),
                          const Text('每周额度',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 16)),
                          const SizedBox(height: 8),
                          const Text('0 表示无可分配时间；修改需要近期多因素认证。',
                              style: TextStyle(color: muted, fontSize: 12)),
                          Wrap(spacing: 8, children: [
                            TextButton(
                                onPressed: locked
                                    ? null
                                    : () => copyDays(
                                        'MONDAY', quotaWeek.keys.take(5)),
                                child: const Text('周一额度应用到工作日')),
                            TextButton(
                                onPressed: locked
                                    ? null
                                    : () => copyDays(
                                        'SATURDAY', ['SATURDAY', 'SUNDAY']),
                                child: const Text('周六额度应用到周末')),
                          ]),
                          LayoutBuilder(
                              builder: (context, size) =>
                                  Wrap(spacing: 16, runSpacing: 16, children: [
                                    for (final day in quotaWeek.entries)
                                      SizedBox(
                                          width: size.maxWidth > 480
                                              ? (size.maxWidth - 16) / 2
                                              : size.maxWidth,
                                          child: TextFormField(
                                              controller: days[day.key],
                                              enabled: !locked,
                                              keyboardType:
                                                  TextInputType.number,
                                              inputFormatters: [
                                                FilteringTextInputFormatter
                                                    .digitsOnly
                                              ],
                                              maxLength: 4,
                                              decoration: InputDecoration(
                                                  labelText: '${day.value}（分钟）',
                                                  helperText: originalSeconds[
                                                                  day.key]! %
                                                              60 !=
                                                          0
                                                      ? '原额度 ${quotaDuration(originalSeconds[day.key])}，不改此项会保留秒数'
                                                      : null),
                                              onChanged: (_) =>
                                                  changedDays.add(day.key),
                                              validator: (v) {
                                                final n = int.tryParse(v ?? '');
                                                return n == null ||
                                                        n < 0 ||
                                                        n > 1440
                                                    ? '请输入 0–1440 分钟'
                                                    : null;
                                              })),
                                  ])),
                          const SizedBox(height: 20),
                          Row(children: [
                            const Expanded(
                                child: Text('日期例外',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 16))),
                            TextButton.icon(
                                onPressed: locked || calendar == null
                                    ? null
                                    : addOverride,
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('添加日期'))
                          ]),
                          if (overrides.isEmpty)
                            const Text('暂无例外，所有日期按星期规则生成。',
                                style: TextStyle(color: muted)),
                          for (final date in (overrides.keys.toList()..sort()))
                            ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(date),
                                subtitle: Text(quotaDuration(overrides[date])),
                                trailing: IconButton(
                                    tooltip: '删除 $date 的例外',
                                    onPressed: locked
                                        ? null
                                        : () => setState(
                                            () => overrides.remove(date)),
                                    icon: const Icon(Icons.close, size: 18))),
                          if (editing) ...[
                            const SizedBox(height: 20),
                            DropdownButtonFormField<String>(
                                value: state,
                                isExpanded: true,
                                decoration:
                                    const InputDecoration(labelText: '生效日之后'),
                                items: const [
                                  DropdownMenuItem(
                                      value: 'ACTIVE', child: Text('每天自动生成额度')),
                                  DropdownMenuItem(
                                      value: 'PAUSED', child: Text('暂停后续日期的生成'))
                                ],
                                onChanged: locked
                                    ? null
                                    : (v) => setState(() => state = v!))
                          ],
                          if (pending != null) ...[
                            const SizedBox(height: 16),
                            const Notice('上次提交结果尚未确认。输入已保留，重试将发送完全相同的内容。',
                                warning: true)
                          ],
                          if (error != null) ...[
                            Padding(
                                key: errorAnchor,
                                padding: const EdgeInsets.only(top: 16),
                                child: FailureView(error!,
                                    reauth: widget.reauth,
                                    retry:
                                        calendar == null ? loadCalendar : null))
                          ],
                        ])))),
        actions: [
          TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
              onPressed: busy || calendar == null ? null : save,
              child: Text(busy
                  ? '保存中…'
                  : pending != null
                      ? '重试原提交'
                      : '保存计划'))
        ],
      ));
}
