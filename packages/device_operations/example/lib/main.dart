import 'package:device_operations/device_operations.dart';
import 'package:flutter/material.dart';
import 'fixtures.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '设备退出组件验收',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'Microsoft YaHei',
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF19335C),
              primary: const Color(0xFF19335C),
              surface: Colors.white),
          scaffoldBackgroundColor: const Color(0xFFF5F7FB),
          filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)))),
          outlinedButtonTheme: OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)))),
        ),
        home: const ShowcasePage(),
      );
}

class ShowcasePage extends StatefulWidget {
  const ShowcasePage({super.key});
  @override
  State<ShowcasePage> createState() => _ShowcasePageState();
}

class _ShowcasePageState extends State<ShowcasePage> {
  late ExitController controller;
  String scenario = 'preview';
  @override
  void initState() {
    super.initState();
    final selected = Uri.base.queryParameters['scenario'];
    if (scenarioLabels.containsKey(selected)) scenario = selected!;
    _create();
  }

  void _create() {
    controller = ExitController(
        scope: fixtureScope(),
        gateway: FixtureGateway(scenario),
        journal: FixtureJournal());
    final current = controller;
    current.initialize().then((_) async {
      if (mounted && identical(current, controller) && scenario != 'reported') {
        await current.prepare();
      }
    });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            title: const Row(children: [
              Icon(Icons.shield_outlined, color: Color(0xFF19335C)),
              SizedBox(width: 10),
              Text('智能管家',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))
            ])),
        body: SingleChildScrollView(
          padding:
              EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 16 : 32),
          child: Center(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1024),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('组件验收 · 设备退出',
                            style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF172238))),
                        const SizedBox(height: 8),
                        const Text('测试夹具，无真实设备操作',
                            style: TextStyle(
                                color: Color(0xFF795016), fontSize: 14)),
                        const SizedBox(height: 24),
                        SizedBox(
                            width: 360,
                            child: DropdownButtonFormField<String>(
                                value: scenario,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                    labelText: '验收场景',
                                    border: OutlineInputBorder()),
                                items: scenarioLabels.entries
                                    .map((e) => DropdownMenuItem(
                                        value: e.key, child: Text(e.value)))
                                    .toList(),
                                onChanged: (value) {
                                  if (value == null) return;
                                  setState(() {
                                    controller.dispose();
                                    scenario = value;
                                    _create();
                                  });
                                })),
                        const SizedBox(height: 24),
                        DeviceExitPanel(
                            key: ValueKey(scenario),
                            controller: controller,
                            deviceName: '测试学习平板 · 家庭自有设备'),
                        const SizedBox(height: 24),
                        const Text(
                            '此入口用于检查组件布局、键盘操作和失败恢复。真实管理台通过已验证的 OIDC 会话和实际 API 接入。',
                            style: TextStyle(
                                color: Color(0xFF67758A), height: 1.6)),
                      ]))),
        ),
      );
}
