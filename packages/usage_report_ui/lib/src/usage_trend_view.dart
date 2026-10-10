import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:usage_reporting/usage_reporting.dart';

import 'design.dart';

class UsageTrendView extends StatefulWidget {
  final List<UsageReportBucket> buckets;
  final String timeZone, period;
  const UsageTrendView(
      {super.key,
      required this.buckets,
      required this.timeZone,
      required this.period});
  @override
  State<UsageTrendView> createState() => _UsageTrendViewState();
}

class _UsageTrendViewState extends State<UsageTrendView> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) {
    final all = widget.buckets,
        trend = usageTrendComparison(all, widget.timeZone, widget.period);
    final shown =
        expanded || all.length <= 7 ? all : all.sublist(all.length - 7);
    final maxMillis =
        all.fold<int>(0, (value, b) => math.max(value, b.upperMillis ?? 0));
    final scale = math.max(1000, ((maxMillis + 999) ~/ 1000) * 1000);
    final scaleText = usageRange(
        UsageReportBucket(1, scale + 1, scale, scale, scale, 'REPORTED_TOTAL'));
    final comparison = switch (trend.status) {
      'INCREASE' => '可推导范围表明使用量增加',
      'DECREASE' => '可推导范围表明使用量减少',
      'UNCHANGED' => '两期汇总时长相同',
      'UNCERTAIN' => '范围重叠，无法确定增减',
      'NO_EVIDENCE' => '证据不足，无法比较',
      'NOT_COMPARABLE' => '时段不连续或长度不同，暂不比较',
      _ => '完整时段不足，暂不比较',
    };
    return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: canvas,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: line)),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('使用趋势', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(comparison),
          if (trend.lowerDeltaMillis != null)
            Text(
                '变化范围：${usageDeltaRange(trend.lowerDeltaMillis!, trend.upperDeltaMillis!)}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          if (trend.previous != null && trend.current != null)
            Text(
                '比较 ${DateFormat('MM-dd').format(usageLocalTime(trend.previous!.start, widget.timeZone))} 与 ${DateFormat('MM-dd').format(usageLocalTime(trend.current!.start, widget.timeZone))} 开始的完整${widget.period == 'DAY' ? '日' : '周'}',
                style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          Text(
              '仅比较最后两个连续、完整且等长的时段。${trend.partialPeriods > 0 ? '${trend.partialPeriods} 个未完整时段仅展示，不参与比较。' : ''}汇总仍未经独立验证。',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 14),
          Text('横条为下界至上界；圆点为汇总值。无证据不按零绘制。',
              style: Theme.of(context).textTheme.bodySmall),
          Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [const Text('0'), Text(scaleText)]),
          for (final bucket in shown)
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                    label:
                        '${usageTimestamp(bucket.start, widget.timeZone)} 至 ${usageTimestamp(bucket.end, widget.timeZone)}：${usageRange(bucket)}',
                    child: ExcludeSemantics(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                          Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              spacing: 12,
                              runSpacing: 4,
                              children: [
                                Text(
                                    '${DateFormat('MM-dd').format(usageLocalTime(bucket.start, widget.timeZone))}${isWholeUsagePeriod(bucket, widget.timeZone, widget.period) ? '' : ' · 未完整'}'),
                                Text(usageRange(bucket)),
                              ]),
                          const SizedBox(height: 5),
                          if (bucket.lowerMillis != null)
                            SizedBox(
                                height: 14,
                                child: LayoutBuilder(builder: (context, space) {
                                  final start = bucket.lowerMillis! /
                                          scale *
                                          space.maxWidth,
                                      end = bucket.upperMillis! /
                                          scale *
                                          space.maxWidth;
                                  final exact =
                                      bucket.lowerMillis == bucket.upperMillis;
                                  return Stack(children: [
                                    Positioned(
                                        left: 0,
                                        right: 0,
                                        top: 6,
                                        child:
                                            Container(height: 2, color: line)),
                                    if (exact)
                                      Positioned(
                                          left: (start - 4).clamp(
                                              0.0,
                                              math.max(
                                                  0.0, space.maxWidth - 8)),
                                          top: 3,
                                          child: Container(
                                              width: 8,
                                              height: 8,
                                              decoration: const BoxDecoration(
                                                  color: navy,
                                                  shape: BoxShape.circle)))
                                    else
                                      Positioned(
                                          left: start.clamp(
                                              0.0,
                                              math.max(
                                                  0.0, space.maxWidth - 3)),
                                          top: 3,
                                          child: Container(
                                              width: math.max(3.0, end - start),
                                              height: 8,
                                              decoration: BoxDecoration(
                                                  color: navy.withOpacity(.7),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          3)))),
                                  ]);
                                })),
                        ])))),
          if (all.length > 7)
            Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                    onPressed: () => setState(() => expanded = !expanded),
                    child: Text(expanded
                        ? '收起至最近 7 个时段'
                        : '展开全部 ${all.length} 个时段（当前显示最近 7 个）'))),
        ]));
  }
}
