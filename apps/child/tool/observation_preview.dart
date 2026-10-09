// Public, credential-free component acceptance fixture. Never a device host.
import 'package:child/ui/design.dart';
import 'package:child/ui/observation_section.dart';
import 'package:device_observation/device_observation.dart';
import 'package:flutter/material.dart';

void main() => runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: childTheme(),
    home: const ObservationPreview()));

class ObservationPreview extends StatefulWidget {
  const ObservationPreview({super.key});
  @override
  State<ObservationPreview> createState() => _PreviewState();
}

class _PreviewState extends State<ObservationPreview> {
  int state = 0, openings = 0;
  static const labels = ['待核对', '待系统许可', '已授权', '离线待发', '已撤回'];
  ObservationView get view {
    if (state == 0) return const ObservationView();
    return ObservationView(
        authorization: ObservationAuthorization(
            deviceId: '11111111-1111-1111-1111-111111111111',
            registrationId: '22222222-2222-2222-2222-222222222222',
            version: state == 4 ? 2 : 1,
            inventoryEnabled: state != 4,
            usageEnabled: state != 4,
            updatedAt: 1791504000000),
        platform: ObservationPlatformState(
            usageGranted: state != 1, unlocked: true, profile: 'PRIMARY'),
        onlineConfirmed: state != 3,
        pendingReports: state == 3 ? 2 : 0,
        inventoryCount: state == 2 ? 19 : 0,
        usageCount: state == 2 ? 2 : 0,
        lastInventoryAt: state == 2 ? 1791504000000 : null,
        lastUsageAt: state == 2 ? 1791504000000 : null);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('儿童端 · 隐私与使用情况')),
      body: SingleChildScrollView(
          child: Center(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const ChildNotice('界面验收样例，不连接真实设备',
                                detail: '下方状态均为公开演示，不读取应用、使用记录或凭据。'),
                            const SizedBox(height: 20),
                            Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: List.generate(
                                    labels.length,
                                    (index) => ChoiceChip(
                                        label: Text(labels[index]),
                                        selected: state == index,
                                        onSelected: (_) =>
                                            setState(() => state = index)))),
                            const Divider(),
                            ObservationSection(
                                view: view,
                                errorCode:
                                    state == 3 ? 'NETWORK_TIMEOUT' : null,
                                refresh: () {},
                                synchronize: () {},
                                openSettings: () => setState(() => openings++)),
                            const Divider(),
                            Text('演示设置确认次数：$openings')
                          ]))))));
}
