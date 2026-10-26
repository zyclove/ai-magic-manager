import 'package:flutter/material.dart';
import 'package:schedule_contracts/schedule_contracts.dart';

import '../core/labels.dart';
import '../ui/design.dart';
import '../ui/leased_dialog.dart';

/// Selects an existing catalog value without saving or changing the draft.
Future<SchedulePreset?> pickSchedulePreset(BuildContext context,
    {required List<SchedulePreset> presets,
    required Listenable accessChanges,
    required bool Function() hasAccess}) {
  final options = List<SchedulePreset>.unmodifiable(presets);
  return leasedDialog<SchedulePreset>(context,
      accessChanges: accessChanges,
      hasAccess: hasAccess,
      builder: (dialog, route, access) {
        bool interactive() =>
            access.permitted() && route.available && route.isCurrent;
        return AlertDialog(
            scrollable: true,
            title: const Text('选择时间安排示例'),
            content: SizedBox(
                width: 560,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Notice('选择后仍可调整。只填入本地草稿，不会保存或发布。'),
                      const SizedBox(height: 12),
                      if (options.isEmpty)
                        const EmptyView('暂无可用示例', '可以返回计划，手动添加每周时段。'),
                      for (final preset in options)
                        Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(preset.name,
                                          style: Theme.of(dialog)
                                              .textTheme
                                              .titleMedium),
                                      if (preset.description.isNotEmpty) ...[
                                        const SizedBox(height: 4),
                                        Text(preset.description),
                                      ],
                                      const SizedBox(height: 12),
                                      if (preset.weekly.isEmpty)
                                        const Text('未设置每周允许时段'),
                                      for (final window in preset.weekly.take(
                                          preset.weekly.length <= 7 ? 7 : 3))
                                        Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 4),
                                            child: Text(_windowText(window))),
                                      if (preset.weekly.length > 7)
                                        ExpansionTile(
                                            tilePadding: EdgeInsets.zero,
                                            title: Text(
                                                '查看其余 ${preset.weekly.length - 3} 个时段'),
                                            children: [
                                              for (final window
                                                  in preset.weekly.skip(3))
                                                Align(
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    child: Padding(
                                                        padding:
                                                            const EdgeInsets
                                                                .only(
                                                                bottom: 4),
                                                        child: Text(
                                                            _windowText(
                                                                window)))),
                                            ]),
                                      const SizedBox(height: 8),
                                      Align(
                                          alignment: Alignment.centerRight,
                                          child: FilledButton.tonal(
                                              key: Key(
                                                  'schedule-preset-use-${preset.id}'),
                                              onPressed: () {
                                                if (interactive()) {
                                                  route.finish(preset);
                                                }
                                              },
                                              child: const Text('使用此示例'))),
                                    ]))),
                    ])),
            actions: [
              TextButton(
                  key: const Key('schedule-preset-cancel'),
                  onPressed: () {
                    if (interactive()) route.finish();
                  },
                  child: const Text('取消')),
            ]);
      });
}

/// Confirms only replacement of the local weekly windows, never a server write.
Future<bool> confirmSchedulePresetReplacement(BuildContext context,
    {required SchedulePreset preset,
    required int currentWindowCount,
    required Listenable accessChanges,
    required bool Function() hasAccess}) async {
  final confirmed = await leasedDialog<bool>(context,
      accessChanges: accessChanges,
      hasAccess: hasAccess,
      builder: (dialog, route, access) {
        bool interactive() =>
            access.permitted() && route.available && route.isCurrent;
        return AlertDialog(
            scrollable: true,
            title: const Text('替换每周时段？'),
            content: SizedBox(
                width: 460,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('将当前 $currentWindowCount 个每周时段替换为'
                          '“${preset.name}”的 ${preset.weekly.length} 个时段。'),
                      const SizedBox(height: 12),
                      const Notice('仅替换每周时段，保留名称、时区和日期例外。'
                          '此操作只更新本地草稿，不会保存或发布。'),
                    ])),
            actions: [
              TextButton(
                  key: const Key('schedule-preset-replace-cancel'),
                  onPressed: () {
                    if (interactive()) route.finish(false);
                  },
                  child: const Text('保留原时段')),
              FilledButton(
                  key: const Key('schedule-preset-replace-confirm'),
                  onPressed: () {
                    if (interactive()) route.finish(true);
                  },
                  child: const Text('替换到草稿')),
            ]);
      });
  return confirmed == true;
}

String _windowText(Map<String, dynamic> window) {
  final start = window['start'] as String, end = window['end'] as String;
  return '${label(window['day'])}  $start – $end'
      '${end.compareTo(start) < 0 ? '（跨午夜，结束于次日）' : ''}';
}
