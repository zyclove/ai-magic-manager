import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/commercial_entitlements.dart';
import 'design.dart';

/// Read-only billing evidence. No purchase actions are shown before a verified channel exists.
class CommercialAccountView extends StatelessWidget {
  final CommercialEntitlements rights;
  const CommercialAccountView({super.key, required this.rights});

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 700;
    final cards = <Widget>[
      _Metric('基础设备名额', rights.baseDeviceCapacity.toString(), '多份基础权益只取最高有效档位'),
      _Metric('加购设备名额', rights.addOnDeviceCapacity.toString(), '仅在有效基础档位上叠加'),
      _Metric('有效来源', rights.activeSourceCount.toString(), '过期或已撤销来源不计入')
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Notice('商业权益与设备可执行能力分别核验。即使已购买，仍须在设备详情确认系统授权、兼容性和策略回执。'),
      const SizedBox(height: 20),
      Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('当前付费设备名额',
            style: TextStyle(color: muted, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Semantics(
            label: '当前付费设备名额 ${rights.paidDeviceCapacity}',
            excludeSemantics: true,
            child: Text('${rights.paidDeviceCapacity}',
                style: const TextStyle(
                    fontSize: 42, fontWeight: FontWeight.w700, color: navy))),
        const SizedBox(height: 8),
        Text(
            rights.activeSourceCount == 0
                ? '暂无经过核验的付费来源。基础安全功能和设备退出不因此关闭。'
                : '由当前有效的基础档位与明确的加购项计算。',
            style: const TextStyle(color: muted)),
        const SizedBox(height: 20),
        if (compact)
          Column(children: [
            for (final card in cards) ...[card, const SizedBox(height: 12)]
          ])
        else
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final card in cards) ...[
              Expanded(child: card),
              if (card != cards.last) const SizedBox(width: 12)
            ]
          ])
      ])),
      const SizedBox(height: 20),
      Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('当前功能权益',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        if (rights.features.isEmpty)
          const Text('暂无已核验的付费功能权益。', style: TextStyle(color: muted))
        else
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final feature in rights.features)
              Chip(label: Text(commercialFeatureLabel(feature)))
          ]),
        const SizedBox(height: 16),
        const Notice('网站过滤、受管设备和智能建议还需单独满足设备模式、授权与地区发布条件；此处只显示商业资格。')
      ])),
      const SizedBox(height: 16),
      Text(
          '权益版本 ${rights.version} · 核算时间 ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(rights.evaluatedAt))}',
          style: const TextStyle(color: muted, fontSize: 12))
    ]);
  }
}

class _Metric extends StatelessWidget {
  final String title, value, hint;
  const _Metric(this.title, this.value, this.hint);

  @override
  Widget build(BuildContext context) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: canvas,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(
                color: ink, fontSize: 24, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(hint, style: const TextStyle(color: muted, fontSize: 11))
      ]));
}
