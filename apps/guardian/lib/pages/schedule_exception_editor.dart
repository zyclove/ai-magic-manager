import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../ui/design.dart';
import '../ui/dialog_access.dart';
import '../ui/leased_dialog.dart';
import '../ui/owned_dialog_route.dart';

String _dateText(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// Selects a date only. Creating or saving its exception is a separate local step.
Future<DateTime?> pickScheduleExceptionDate(BuildContext context,
    {required Listenable accessChanges,
    required bool Function() hasAccess}) async {
  final first = DateTime(1900), last = DateTime(2200, 12, 31);
  final today = DateUtils.dateOnly(DateTime.now());
  var selected = today.isBefore(first)
      ? first
      : today.isAfter(last)
          ? last
          : today;
  return leasedDialog<DateTime>(context,
      accessChanges: accessChanges,
      hasAccess: hasAccess, builder: (dialog, route, access) {
    bool interactive() =>
        access.permitted() && route.available && route.isCurrent;
    return AlertDialog(
        scrollable: true,
        title: const Text('选择日期例外'),
        content: SizedBox(
            width: 360,
            height: 360,
            child: CalendarDatePicker(
                initialDate: selected,
                firstDate: first,
                lastDate: last,
                onDateChanged: (value) {
                  if (interactive()) selected = DateUtils.dateOnly(value);
                })),
        actions: [
          TextButton(
              onPressed: () {
                if (interactive()) route.finish();
              },
              child: const Text('取消')),
          FilledButton(
              key: const Key('schedule-exception-date-apply'),
              onPressed: () {
                if (interactive()) route.finish(selected);
              },
              child: const Text('选择日期')),
        ]);
  });
}

/// Returns a detached exception for the local draft; it never sends a request.
Future<Json?> editScheduleException(BuildContext context,
    {required DateTime date,
    Json? initial,
    required Listenable accessChanges,
    required bool Function() hasAccess}) async {
  if (date.year < 1900 || date.year > 2200) {
    throw ArgumentError.value(date, 'date', '日期必须在 1900 至 2200 年之间');
  }
  final windows = <Json>[];
  if (initial != null) {
    final source = initial['windows'];
    if (source is! List || source.length > 8) {
      throw ArgumentError.value(initial, 'initial', '日期例外最多包含 8 个时段');
    }
    for (final window in source) {
      if (window is! Json ||
          !_validTime(window['start']) ||
          !_validTime(window['end'])) {
        throw ArgumentError.value(initial, 'initial', '时段必须使用 HH:mm 格式');
      }
      windows.add(jsonDecode(jsonEncode(window)) as Json);
    }
  }
  return leasedDialog<Json>(context,
      accessChanges: accessChanges,
      hasAccess: hasAccess,
      builder: (dialog, route, access) => _ExceptionEditor(
          date: DateUtils.dateOnly(date),
          initialWindows: windows,
          initiallyClosed: initial != null && windows.isEmpty,
          route: route,
          access: access));
}

bool _validTime(Object? value) {
  if (value is! String) return false;
  final match = RegExp(r'(?:[01][0-9]|2[0-3]):[0-5][0-9]').firstMatch(value);
  return match != null && match.start == 0 && match.end == value.length;
}

class _ExceptionEditor extends StatefulWidget {
  final DateTime date;
  final List<Json> initialWindows;
  final bool initiallyClosed;
  final OwnedDialogRoute<Json> route;
  final DialogAccessBinding access;

  const _ExceptionEditor(
      {required this.date,
      required this.initialWindows,
      required this.initiallyClosed,
      required this.route,
      required this.access});

  @override
  State<_ExceptionEditor> createState() => _ExceptionEditorState();
}

class _ExceptionEditorState extends State<_ExceptionEditor> {
  late final List<Json> windows = widget.initialWindows;
  late bool closed = widget.initiallyClosed;
  bool picking = false;

  bool get current =>
      mounted && widget.access.permitted() && widget.route.available;
  bool get interactive => current && widget.route.isCurrent && !picking;
  bool get invalid => windows.any((window) => window['start'] == window['end']);
  bool get canApply => closed || (windows.isNotEmpty && !invalid);

  void changeMode(bool? value) {
    if (!interactive || value == null) return;
    setState(() => closed = value);
  }

  void add() {
    if (!interactive || closed || windows.length >= 8) return;
    setState(() => windows.add({'start': '18:00', 'end': '20:00'}));
  }

  void remove(Json window) {
    if (!interactive || closed || !windows.contains(window)) return;
    setState(() => windows.remove(window));
  }

  Future<void> pick(Json window, String field) async {
    if (!interactive || closed || !windows.contains(window)) return;
    final text = window[field] as String;
    setState(() => picking = true);
    try {
      final value = await leasedDialog<TimeOfDay>(context,
          accessChanges: widget.access.changes,
          hasAccess: () => current && windows.contains(window),
          builder: (dialog, route, access) => MediaQuery(
              data: MediaQuery.of(dialog).copyWith(alwaysUse24HourFormat: true),
              child: Navigator(
                  pages: [
                    MaterialPage<TimeOfDay>(
                        child: TimePickerDialog(
                            initialTime: TimeOfDay(
                                hour: int.parse(text.substring(0, 2)),
                                minute: int.parse(text.substring(3, 5))),
                            initialEntryMode: TimePickerEntryMode.input,
                            helpText: field == 'start' ? '选择开始时间' : '选择结束时间',
                            cancelText: '取消',
                            confirmText: '确定',
                            hourLabelText: '时',
                            minuteLabelText: '分',
                            errorInvalidText: '请输入有效时间')),
                  ],
                  // Keep the stock picker's Navigator.pop local to this lease.
                  onPopPage: (_, result) {
                    if (access.permitted() &&
                        route.available &&
                        route.isCurrent) {
                      route.finish(result is TimeOfDay ? result : null);
                    }
                    return false;
                  })));
      if (!current ||
          !widget.route.isCurrent ||
          !windows.contains(window) ||
          value == null) return;
      setState(() => window[field] = '${value.hour.toString().padLeft(2, '0')}:'
          '${value.minute.toString().padLeft(2, '0')}');
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  void apply() {
    if (!interactive || !canApply) return;
    widget.route.finish({
      'date': _dateText(widget.date),
      'windows': closed ? <Json>[] : jsonDecode(jsonEncode(windows)),
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          scrollable: true,
          title: Text('${_dateText(widget.date)} 日期例外'),
          content: SizedBox(
              width: 480,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Notice('仅应用到本地草稿，尚未提交到服务器。日期固定，可返回计划删除或另建。'),
                    RadioListTile<bool>(
                        key: const Key('schedule-exception-mode-closed'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('全天关闭'),
                        subtitle: const Text('该日期不设置允许时段'),
                        value: true,
                        groupValue: closed,
                        onChanged: picking ? null : changeMode),
                    RadioListTile<bool>(
                        key: const Key('schedule-exception-mode-custom'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('自定义时段'),
                        subtitle: const Text('使用这里的时段替代当天的每周安排'),
                        value: false,
                        groupValue: closed,
                        onChanged: picking ? null : changeMode),
                    if (!closed) ...[
                      const Text('每天 1–8 个时段。结束时间早于开始时间时，结束于次日。'),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                          key: const Key('schedule-exception-add'),
                          onPressed:
                              picking || windows.length >= 8 ? null : add,
                          icon: const Icon(Icons.add),
                          label: Text('添加时段（${windows.length}/8）')),
                      for (final entry in windows.asMap().entries)
                        Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  Text('时段 ${entry.key + 1}'),
                                  OutlinedButton(
                                      key: Key(
                                          'schedule-exception-start-${entry.key}'),
                                      onPressed: picking
                                          ? null
                                          : () => pick(entry.value, 'start'),
                                      child: Text(entry.value['start'])),
                                  const Text('至'),
                                  OutlinedButton(
                                      key: Key(
                                          'schedule-exception-end-${entry.key}'),
                                      onPressed: picking
                                          ? null
                                          : () => pick(entry.value, 'end'),
                                      child: Text(entry.value['end'])),
                                  if ((entry.value['end'] as String)
                                          .compareTo(entry.value['start']) <
                                      0)
                                    const Text('跨午夜，结束于次日'),
                                  IconButton(
                                      key: Key(
                                          'schedule-exception-remove-${entry.key}'),
                                      tooltip: '删除时段 ${entry.key + 1}',
                                      onPressed: picking
                                          ? null
                                          : () => remove(entry.value),
                                      icon: const Icon(Icons.delete_outline)),
                                ])),
                      if (windows.isEmpty)
                        const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('请添加至少一个时段，或选择全天关闭。')),
                      if (invalid)
                        const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child:
                                Notice('开始和结束时间不能相同。请调整后再应用。', warning: true)),
                    ],
                  ])),
          actions: [
            TextButton(
                key: const Key('schedule-exception-cancel'),
                onPressed: picking
                    ? null
                    : () {
                        if (interactive) widget.route.finish();
                      },
                child: const Text('取消')),
            FilledButton(
                key: const Key('schedule-exception-apply'),
                onPressed: picking || !canApply ? null : apply,
                child: const Text('应用到草稿')),
          ]);
}
