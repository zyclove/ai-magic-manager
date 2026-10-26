import 'package:flutter/material.dart';
import 'package:schedule_contracts/schedule_contracts.dart';

import '../core/labels.dart';
import 'design.dart';

/// Groups the draft for display without sorting or merging its original rows.
class ScheduleWeekView extends StatelessWidget {
  final List<Map<String, dynamic>> windows;
  final ValueChanged<Map<String, dynamic>>? onRemove;

  const ScheduleWeekView({super.key, required this.windows, this.onRemove});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
      builder: (context, constraints) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('已加入 ${windows.length}/$maximumWeeklyWindows 个每周时段',
                    style: const TextStyle(color: muted, fontSize: 12)),
                if (windows.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  const Text('按开始星期显示；跨午夜的结束时间属于次日。',
                      style: TextStyle(color: muted, fontSize: 12)),
                ],
                for (final day in const [
                  'MONDAY',
                  'TUESDAY',
                  'WEDNESDAY',
                  'THURSDAY',
                  'FRIDAY',
                  'SATURDAY',
                  'SUNDAY',
                ])
                  if (windows.any((window) => window['day'] == day))
                    Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(label(day),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              Wrap(spacing: 8, runSpacing: 8, children: [
                                for (final entry in windows.asMap().entries)
                                  if (entry.value['day'] == day)
                                    ConstrainedBox(
                                        constraints: BoxConstraints(
                                            maxWidth: constraints.maxWidth),
                                        child: InputChip(
                                            key: ValueKey(
                                                'schedule-weekly-window-${entry.key}'),
                                            label: Text(_range(entry.value)),
                                            deleteButtonTooltipMessage:
                                                '移除${label(day)} ${_range(entry.value)}',
                                            onDeleted: onRemove == null
                                                ? null
                                                : () => onRemove!(entry.value))),
                              ]),
                            ])),
              ]));
}

String _range(Map<String, dynamic> window) {
  final start = window['start'] as String, end = window['end'] as String;
  return '$start – $end${end.compareTo(start) < 0 ? '（次日）' : ''}';
}
