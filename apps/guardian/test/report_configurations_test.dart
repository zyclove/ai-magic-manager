import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/report_configurations.dart';
import 'package:guardian/ui/report_configurations_view.dart';

const checked = 1791586800000;
Map<String, dynamic> configurationFixture() => {
      'checkedAt': checked,
      'evidenceStatus': 'DELIVERY_ONLY_NOT_EXECUTION',
      'configurations': [
        {
          'id': '11111111-1111-1111-1111-111111111111',
          'policyId': '22222222-2222-2222-2222-222222222222',
          'versionId': '33333333-3333-3333-3333-333333333333',
          'sourceSequence': 1,
          'action': 'UPSERT_CONFIGURATION',
          'deliveryState': 'DEVICE_REPORTED_STORED',
          'issuedAt': checked - 60000,
          'deliveryExpiresAt': checked + 60000,
          'firstServedAt': checked - 50000,
          'receivedReportedAt': checked - 40000,
          'storedReportedAt': checked - 30000,
          'rejectionCode': null,
          'name': '晚间学习提醒',
          'rules': [
            {
              'kind': 'USAGE_REMINDER',
              'predictedEffect': 'REMIND',
              'status': 'UNKNOWN',
              'reasonCode': 'CAPABILITY_NOT_VERIFIED',
              'applicationName': null,
              'platform': null,
              'profile': null,
              'packageName': null,
              'scheduleName': null,
              'permission': null,
              'domain': null,
              'seconds': 900,
              'required': false
            }
          ]
        }
      ]
    };

void main() {
  testWidgets('saved report labels configuration as generated snapshot',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ReportConfigurationsView(
                state: ReportConfigurationState.parse(
                    configurationFixture(), checked),
                timeZone: 'UTC',
                historical: true))));
    expect(find.text('生成时的规则与下发状态 · 1 项'), findsOneWidget);
    expect(find.text('当前规则与下发状态 · 1 项'), findsNothing);
  });
  test('current configuration receipts are parsed separately from execution',
      () {
    final state =
        ReportConfigurationState.parse(configurationFixture(), checked);
    expect(state.configurations.single.deliveryState, 'DEVICE_REPORTED_STORED');
    expect(state.configurations.single.rules.single.kind, 'USAGE_REMINDER');
    expect(() => state.configurations.clear(), throwsUnsupportedError);
    expect(() => state.configurations.single.rules.clear(),
        throwsUnsupportedError);
  });
  test(
      'malformed timestamps, execution claims, unknown states and incomplete fields fail closed',
      () {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (v) => v['evidenceStatus'] = 'EXECUTED',
      (v) => v['checkedAt'] = checked - 1,
      (v) => v['configurations'][0]['deliveryState'] = 'EXECUTED',
      (v) => v['configurations'][0]['storedReportedAt'] = null,
      (v) => v['configurations'][0]['firstServedAt'] = checked + 1,
      (v) => v['configurations'][0]['action'] = 'REMOVE_CONFIGURATION',
      (v) => v['configurations'][0]['rules'][0]['effectiveEffect'] = 'ALLOW',
      (v) =>
          v['configurations'][0]['rules'][0]['packageName'] = 'org.other.app',
      (v) => v['configurations'][0].remove('rejectionCode'),
      (v) => v['configurations'].add(v['configurations'][0]),
    ]) {
      final raw = configurationFixture();
      mutate(raw);
      expect(() => ReportConfigurationState.parse(raw, checked),
          throwsA(isA<UsageReportFailure>()));
    }
  });
  testWidgets('mobile current rule details explain receipt limitations',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: ReportConfigurationsView(
                    state: ReportConfigurationState.parse(
                        configurationFixture(), checked),
                    timeZone: 'UTC')))));
    await tester.tap(find.text('当前规则与下发状态 · 1 项'));
    await tester.pumpAndSettle();
    expect(find.text('设备报告已保存'), findsOneWidget);
    expect(find.textContaining('不证明规则已在系统执行'), findsOneWidget);
    expect(find.textContaining('使用提醒'), findsOneWidget);
    expect(find.text('配置时长：15 分钟'), findsOneWidget);
    expect(find.text('发布时能力：尚未确认'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
