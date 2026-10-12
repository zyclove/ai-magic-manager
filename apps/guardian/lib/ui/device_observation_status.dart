import 'package:flutter/material.dart';
import '../core/labels.dart';

/// Server observation is connectivity evidence, never proof of local enforcement.
class DeviceObservationStatus extends StatelessWidget {
  final Object? value;
  const DeviceObservationStatus(this.value, {super.key});

  static String explanation(Object? value) => switch (value) {
        'RECENT' => '服务端近期收到设备心跳；应用限制是否执行仍需查看能力和执行回执。',
        'STALE' => '设备心跳超过服务端观察时限。请检查设备网络、电源和设备应用；失联不能证明规则已失效或孩子绕过管控。',
        'UNKNOWN' => '尚无可用心跳，暂时无法判断设备连接情况。请检查注册与设备应用。',
        'REVOKED' => '云端设备注册已撤销，无法继续观察该注册周期；本地系统管理状态需单独核实。',
        _ => '设备观察状态暂不可用，请刷新后查看设备诊断。',
      };

  @override
  Widget build(BuildContext context) {
    final status = value?.toString();
    final color = switch (status) {
      'RECENT' => const Color(0xFF00886C),
      'STALE' => const Color(0xFFA65B17),
      'REVOKED' => const Color(0xFFA7473C),
      _ => const Color(0xFF68788F),
    };
    final icon = switch (status) {
      'RECENT' => Icons.wifi_rounded,
      'STALE' => Icons.wifi_off_rounded,
      'REVOKED' => Icons.link_off_rounded,
      _ => Icons.help_outline_rounded,
    };
    return Tooltip(
        message: explanation(status),
        child: Semantics(
            label: '设备观察：${label(status)}。${explanation(status)}',
            child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                    color: color.withOpacity(.08),
                    borderRadius: BorderRadius.circular(6)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 14, color: color),
                  const SizedBox(width: 5),
                  Text(label(status),
                      style: TextStyle(
                          color: color,
                          fontSize: 12,
                          fontWeight: FontWeight.w500))
                ]))));
  }
}
