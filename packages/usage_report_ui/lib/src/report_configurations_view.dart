import 'package:flutter/material.dart';
import 'design.dart';

import 'package:usage_reporting/usage_reporting.dart';

const _ruleStatusLabels = {
  'UNKNOWN': '尚未确认',
  'UNVERIFIED': '设备报告尚未验证',
  'UNAVAILABLE': '不可用',
  'UNSUPPORTED': '当前不支持',
  'SUPPORTED_PENDING': '能力已确认 · 等待执行',
  'STALE': '能力证据已过期',
};

String _configuredDuration(int seconds) {
  if (seconds % 3600 == 0) return '${seconds ~/ 3600} 小时';
  if (seconds % 60 == 0) return '${seconds ~/ 60} 分钟';
  return '$seconds 秒';
}

class ReportConfigurationsView extends StatelessWidget {
  final ReportConfigurationState state;
  final String timeZone;
  final bool historical;
  const ReportConfigurationsView(
      {super.key,
      required this.state,
      required this.timeZone,
      this.historical = false});
  @override
  Widget build(BuildContext context) => ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 16),
          title: Text(
              '${historical ? '生成时的' : '当前'}规则与下发状态 · ${state.configurations.length} 项'),
          subtitle: Text('检查于 ${usageTimestamp(state.checkedAt, timeZone)}'),
          children: [
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                  '这里展示${historical ? '报表生成时的' : '当前'}配置及设备回执，不是所选历史时段的执行记录。接收或保存回执不证明规则已在系统执行；使用趋势也不能证明规则产生了效果。'),
              const SizedBox(height: 12),
              if (state.configurations.isEmpty)
                const Text('当前注册周期暂无配置下发记录。这不表示设备没有本地或系统规则。'),
              for (final item in state.configurations) ...[
                const Divider(),
                Text(item.name ?? '移除已发布配置',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                Text(configurationDeliveryLabels[item.deliveryState]!,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(item.action == 'REMOVE_CONFIGURATION'
                    ? '这是移除配置指令；仍需设备执行证据确认实际结果。'
                    : '配置目标 · 第 ${item.sourceSequence} 次发布；执行结果尚未确认'),
                Text('发布于 ${usageTimestamp(item.issuedAt, timeZone)}'),
                Text(
                    '本次交付有效至 ${usageTimestamp(item.deliveryExpiresAt, timeZone)}'),
                if (item.firstServedAt != null)
                  Text(
                      '提供给设备 ${usageTimestamp(item.firstServedAt!, timeZone)}'),
                if (item.receivedReportedAt != null)
                  Text(
                      '接收回执 ${usageTimestamp(item.receivedReportedAt!, timeZone)}'),
                if (item.storedReportedAt != null)
                  Text(
                      '保存回执 ${usageTimestamp(item.storedReportedAt!, timeZone)}'),
                if (item.rejectionCode != null)
                  Text(configurationRejectionLabels[item.rejectionCode]!),
                if (item.deliveryState == 'DEVICE_REPORTED_REJECTED')
                  const Text('请检查设备连接、版本与存储状态；修复后由有权限的管理员重新发布配置。'),
                if (item.deliveryState == 'EXPIRED_AWAITING_PULL')
                  const Text('请保持设备连接，等待重新拉取。交付有效期不等于已保存配置的规则有效期。'),
                for (final rule in item.rules)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                '${label(rule.kind)} · 配置目标：${label(rule.predictedEffect)}'),
                            if (rule.applicationName != null)
                              Text(
                                  '${rule.applicationName} · ${label(rule.profile)} · ${rule.packageName}'),
                            if (rule.scheduleName != null)
                              Text('关联时间计划：${rule.scheduleName}'),
                            if (rule.permission != null)
                              Text('权限：${rule.permission}'),
                            if (rule.domain != null) Text('域名：${rule.domain}'),
                            if (rule.seconds != null)
                              Text(
                                  '配置时长：${_configuredDuration(rule.seconds!)}'),
                            Text(
                                '发布时能力：${_ruleStatusLabels[rule.status]}${rule.required ? ' · 必需规则' : ''}'),
                            Text(
                                '限制说明：${configurationReasonLabels[rule.reasonCode] ?? '尚无可确认的执行证据，请检查设备能力和发布详情。'}'),
                          ])),
                const SizedBox(height: 8),
                SelectableText('配置版本 ${item.versionId}',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ])
          ]);
}
