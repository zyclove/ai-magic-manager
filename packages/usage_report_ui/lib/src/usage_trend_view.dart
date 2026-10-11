import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:usage_reporting/usage_reporting.dart';

import 'design.dart';

class UsageTrendView extends StatefulWidget {
  final List<UsageReportBucket> buckets;
  final String timeZone, period;
  final VoidCallback? onReviewRules, onCheckDevice;
  const UsageTrendView(
      {super.key,
      required this.buckets,
      required this.timeZone,
      required this.period,
      this.onReviewRules,
      this.onCheckDevice});
  @override
  State<UsageTrendView> createState() => _UsageTrendViewState();
}

class _UsageTrendViewState extends State<UsageTrendView> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) {
    final all = widget.buckets,
        insight =
            usageInsightForApplication(all, widget.timeZone, widget.period),
        trend = insight.comparison;
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
          _UsageInsightCard(
              insight: insight,
              onReviewRules: widget.onReviewRules,
              onCheckDevice: widget.onCheckDevice),
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

/// A human-review prompt. It never edits policy or labels a child's health.
class _UsageInsightCard extends StatelessWidget {
  final UsageInsight insight;
  final VoidCallback? onReviewRules, onCheckDevice;
  const _UsageInsightCard(
      {required this.insight, this.onReviewRules, this.onCheckDevice});

  @override
  Widget build(BuildContext context) {
    final (title, description, icon) = switch (insight.kind) {
      UsageInsightKind.reviewIncrease => (
          '建议回看使用安排',
          '这两段完整时段的应用使用范围显示增加。可以与儿童讨论原因，再由有权限的成人决定是否调整提醒或作息。',
          Icons.tips_and_updates_outlined,
        ),
      UsageInsightKind.reviewDecrease => (
          '近期使用有所减少',
          '这两段完整时段的应用使用范围显示减少。可结合学习与休息安排继续观察。',
          Icons.trending_down,
        ),
      UsageInsightKind.keepObserving => (
          '继续观察',
          '这两段完整时段报告的应用使用时长相同。单次比较不足以说明长期习惯。',
          Icons.visibility_outlined,
        ),
      UsageInsightKind.checkEvidence => (
          '先核对数据覆盖',
          '目前无法可靠判断增减。请检查设备连接、观察授权与缺失时段，再决定是否调整规则。',
          Icons.fact_check_outlined,
        ),
    };
    final evidence = insight.comparedPeriods == 2 &&
            insight.comparison.lowerDeltaMillis != null
        ? '依据：两个连续、完整且等长的时段；变化范围 ${usageDeltaRange(insight.comparison.lowerDeltaMillis!, insight.comparison.upperDeltaMillis!)}。'
        : '依据：${insight.comparison.partialPeriods} 个不完整时段未参与比较；${switch (insight.comparison.status) {
            'NO_EVIDENCE' => '完整时段仍缺少使用证据。',
            'NOT_COMPARABLE' => '最近两个完整时段不连续或长度不同。',
            'UNCERTAIN' => '上下界重叠，不能确定方向。',
            _ => '可比较的完整时段不足。',
          }}';
    final action = insight.kind == UsageInsightKind.checkEvidence
        ? onCheckDevice
        : onReviewRules;
    final actionLabel =
        insight.kind == UsageInsightKind.checkEvidence ? '查看设备与授权' : '前往规则中心';
    return Semantics(
        container: true,
        child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: const Color(0xFFEAF3F2),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: line)),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon, color: navy),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(title,
                        style: Theme.of(context).textTheme.titleSmall))
              ]),
              const SizedBox(height: 8),
              Text(description),
              const SizedBox(height: 8),
              Text(evidence, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              Text('仅使用本次已授权报表在本机生成；不自动修改规则，不作健康或身份判断。',
                  style: Theme.of(context).textTheme.bodySmall),
              if (action != null) ...[
                const SizedBox(height: 10),
                Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                        onPressed: action,
                        icon: const Icon(Icons.arrow_forward, size: 18),
                        label: Text(actionLabel)))
              ]
            ])));
  }
}
