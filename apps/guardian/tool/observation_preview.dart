// Public state fixture. No auth, real data or service connections.
import 'package:flutter/material.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/observation.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/observation_editor.dart';
import 'package:guardian/ui/observation_view.dart';

void main() => runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: consoleTheme(),
    home: const Preview()));

class Preview extends StatefulWidget {
  const Preview({super.key});
  @override
  State<Preview> createState() => _PreviewState();
}

class _PreviewState extends State<Preview> {
  static const device = '22222222-2222-2222-2222-222222222222';
  static const registration = '33333333-3333-3333-3333-333333333333';
  static const now = 1791504000000;
  int state = 0, writes = 0;
  final labels = ['已授权', '只读', '已撤回', '服务错误', '重试演示'];
  ManagedObservationSettings settings = const ManagedObservationSettings(
      device, registration, 1, true, true, now);
  final batch = const ObservedUsageBatch(
      registration,
      '44444444-4444-4444-4444-444444444444',
      9,
      1,
      'PRIMARY',
      now - 3600000,
      now,
      now,
      'Asia/Shanghai',
      [
        ObservedUsageApplication(
            'org.example.reader', '演示阅读应用', now - 7200000, now, 120000)
      ],
      now);
  void select(int value) => setState(() {
        state = value;
        writes = 0;
        settings = ManagedObservationSettings(device, registration,
            value == 2 ? 2 : 1, value != 2, value != 2, now);
      });
  Future<void> edit() async {
    await showDialog<Json>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ObservationEditor(
            before: settings,
            onSubmit: (body) async {
              writes++;
              if (state == 4 && writes == 1) {
                throw const ApiFailure(503, 'SERVICE_UNAVAILABLE');
              }
              setState(() => settings = ManagedObservationSettings(
                  device,
                  registration,
                  settings.version + 1,
                  body['inventoryEnabled'],
                  body['usageEnabled'],
                  now));
            }));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('管理工作台 · 设备观察')),
      body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Notice('公开界面验收样例，全部为演示数据；不连接真实设备、账户或后端。'),
                        const SizedBox(height: 16),
                        Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: List.generate(
                                labels.length,
                                (index) => ChoiceChip(
                                    label: Text(labels[index]),
                                    selected: state == index,
                                    onSelected: (_) => select(index)))),
                        const SizedBox(height: 24),
                        ObservationView(
                            deviceName: '演示学习平板',
                            canEdit: state != 1,
                            snapshot: state == 3
                                ? null
                                : ObservationSnapshot(settings,
                                    settings.usageEnabled ? [batch] : [], null),
                            error: state == 3
                                ? const ApiFailure(
                                    502, 'INVALID_OBSERVATION_RESPONSE')
                                : null,
                            refresh: () {},
                            edit: edit),
                        const SizedBox(height: 24),
                        Text('演示提交次数：$writes'),
                      ])))));
}
