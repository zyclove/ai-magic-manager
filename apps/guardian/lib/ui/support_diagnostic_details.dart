import 'package:flutter/material.dart';
import '../core/device_diagnostic.dart';
import '../core/support_diagnostic.dart';
import 'diagnostic_preview_view.dart' show label, capabilityName;
import 'support_view_state.dart';

class SupportDiagnosticDetails extends StatelessWidget {
  final SupportDiagnostic value;
  const SupportDiagnosticDetails(this.value, {super.key});
  String time(int? value) => value == null ? '尚无记录' : supportTime(value);
  String version(DiagnosticVersion value) => value.status == 'REPORTED'
      ? value.value!
      : value.status == 'REDACTED'
          ? '已脱敏'
          : '尚未报告';
  @override
  Widget build(BuildContext context) {
    Widget fact(String title, String text) => supportFact(context, title, text);
    final device = value.device, versions = value.versions;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('设备自报与下发记录，不代表策略已执行。'),
      const SizedBox(height: 8),
      Text('读取时间：${supportTime(value.generatedAt)} · 本机时间'),
      const SizedBox(height: 16),
      if (device != null && versions != null) ...[
        Text('设备状态与版本', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        fact('设备状态', label(device.state)),
        fact('平台', device.platform == 'ANDROID_TV' ? 'Android TV' : 'Android'),
        fact('系统版本', version(versions.os)),
        fact('设备应用版本', version(versions.agent)),
        fact('服务端版本', version(versions.server)),
        fact('管理模式', label(device.managementMode)),
        fact('控制能力', label(device.controlLevel)),
        fact('心跳观察', label(device.observationStatus)),
        fact('最后心跳', time(device.lastHeartbeatAt)),
      ],
      if (value.capabilities != null) ...[
        Text('设备能力与授权状态', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        if (value.capabilities!.isEmpty) const Text('尚无可识别的能力记录。'),
        for (final capability in value.capabilities!)
          Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(capabilityName(capability.key),
                        style: Theme.of(context).textTheme.titleSmall),
                    Text(
                        '${label(capability.status)} · ${label(capability.grantStatus)}'),
                    Text(
                        '设备自报${capability.reportedSupported ? '支持' : '不支持'} · ${label(capability.evidenceSource)}'),
                    Text('检查时间：${time(capability.checkedAt)}'),
                    Text(label(capability.limitationCode))
                  ])),
        if (value.omittedCapabilityCount! > 0)
          Text('${value.omittedCapabilityCount} 项未知能力已隐藏。'),
      ],
      if (value.configurations != null) ...[
        Text('配置下发记录与指纹', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        if (value.configurations!.isEmpty) const Text('当前注册周期尚无配置下发记录。'),
        for (final entry in value.configurations!.indexed)
          ExpansionTile(
              key: ValueKey('${value.generatedAt}/${entry.$2.id}'),
              tilePadding: EdgeInsets.zero,
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              title: Text('配置 ${entry.$1 + 1}'),
              subtitle: Text(label(entry.$2.deliveryState)),
              children: [
                fact('操作', label(entry.$2.action)),
                fact('版本序号', '${entry.$2.sourceSequence}'),
                fact('下发时间', time(entry.$2.issuedAt)),
                fact('下发到期', time(entry.$2.deliveryExpiresAt)),
                fact('设备报告收到', time(entry.$2.receivedReportedAt)),
                fact('设备报告保存', time(entry.$2.storedReportedAt)),
                if (entry.$2.rejectionCode != null)
                  fact('拒绝原因', label(entry.$2.rejectionCode!)),
                fact('配置标识', entry.$2.id),
                fact('策略标识', entry.$2.policyId),
                fact('策略版本标识', entry.$2.versionId),
                fact('策略指纹', entry.$2.policyHash ?? '尚无有效指纹'),
                fact('下发指纹', entry.$2.configurationHash ?? '尚无有效指纹')
              ]),
      ],
      const SizedBox(height: 16),
      fact('请求标识', value.correlationId),
    ]);
  }
}
