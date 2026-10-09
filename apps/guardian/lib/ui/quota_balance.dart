import 'package:flutter/material.dart';
import '../core/api.dart';
import 'design.dart';

String quotaDuration(dynamic seconds) {
  final value = (seconds as num).toInt();
  if (value < 60) return '$value 秒';
  return value % 60 == 0
      ? '${value ~/ 60} 分钟'
      : '${value ~/ 60} 分 ${value % 60} 秒';
}

String quotaDelta(dynamic seconds) =>
    '${(seconds as num) > 0 ? '+' : seconds < 0 ? '−' : ''}${quotaDuration(seconds.abs())}';
String quotaKind(String kind) =>
    const {
      'CREATED': '建立额度',
      'ADJUSTED': '管理员调整',
      'RESERVED': '设备预留',
      'SETTLED': '累计结算',
      'RELEASED': '确认归还'
    }[kind] ??
    kind;

class QuotaBalance extends StatelessWidget {
  final Json pool;
  const QuotaBalance({super.key, required this.pool});
  @override
  Widget build(BuildContext context) {
    final limit = (pool['limitSeconds'] as num).toInt();
    final used = (pool['usedSeconds'] as num).toInt();
    final reserved = (pool['reservedSeconds'] as num).toInt();
    final available = (pool['availableSeconds'] as num).toInt();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('总额度 ${quotaDuration(limit)}',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
      const SizedBox(height: 18),
      Semantics(
          label:
              '已结算 ${quotaDuration(used)}，待确认预留 ${quotaDuration(reserved)}，可分配 ${quotaDuration(available)}',
          child: ExcludeSemantics(
              child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                      height: 14,
                      child: Row(children: [
                        if (used > 0)
                          Expanded(flex: used, child: Container(color: navy)),
                        if (reserved > 0)
                          Expanded(
                              flex: reserved,
                              child: Container(color: const Color(0xFFCE921A))),
                        if (available > 0 || limit == 0)
                          Expanded(
                              flex: available > 0 ? available : 1,
                              child: Container(color: const Color(0xFFE6ECF4))),
                      ]))))),
      const SizedBox(height: 18),
      Wrap(spacing: 22, runSpacing: 12, children: [
        Text('已结算 ${quotaDuration(used)}'),
        Text('待确认预留 ${quotaDuration(reserved)}'),
        Text('可分配 ${quotaDuration(available)}',
            style: const TextStyle(fontWeight: FontWeight.w600))
      ]),
    ]);
  }
}
