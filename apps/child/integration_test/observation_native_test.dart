import 'dart:convert';
import 'package:child/platform/observation_source.dart';
import 'package:device_observation/device_observation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 仅本任务测试模拟器；系统 AppOps 由宿主 adb 显式设置，不伪造系统授权。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('official Android observation bridge and special access',
      (tester) async {
    const allowed = bool.fromEnvironment('EXPECT_USAGE_ALLOWED');
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Text('Android observation verification'))));
    final source = AndroidObservationSource();
    final facts = await source.inspect();
    expect(facts.unlocked, isTrue);
    expect(facts.usageSupported, isTrue);
    expect(facts.usageGranted, allowed);
    final applications = await source.inventory();
    expect(applications, isNotEmpty);
    expect(applications.length, lessThanOrEqualTo(500));
    final own = applications.singleWhere(
        (app) => app['packageName'] == 'com.aimanager.child.debug');
    expect(own['signingDigests'], isNotEmpty);
    expect(
        (own['signingDigests'] as List)
            .every((v) => v is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(v)),
        isTrue);
    final now = DateTime.now().millisecondsSinceEpoch;
    var count = 0;
    if (allowed) {
      final sample =
          await source.usage(queryStart: now - 3600000, queryEnd: now);
      expect(sample.queryStart, now - 3600000);
      expect(sample.queryEnd, now);
      expect(sample.timeZone, isNotEmpty);
      expect(sample.profile, facts.profile);
      expect(sample.applications.length, lessThanOrEqualTo(500));
      count = sample.applications.length;
      for (final app in sample.applications) {
        expect(app['firstTimeStamp'] as int,
            lessThanOrEqualTo(app['lastTimeStamp'] as int));
        expect(
            app['foregroundMillis'] as int,
            lessThanOrEqualTo((app['lastTimeStamp'] as int) -
                (app['firstTimeStamp'] as int)));
      }
    } else {
      await expectLater(
          source.usage(queryStart: now - 3600000, queryEnd: now),
          throwsA(isA<ObservationFailure>()
              .having((e) => e.code, 'code', 'USAGE_ACCESS_NOT_GRANTED')));
    }
    // 只记录覆盖计数，不写应用名、签名、使用载荷、凭证或原始行为。
    debugPrint('OBSERVATION_NATIVE_RESULT ${jsonEncode({
          'usageAllowed': allowed,
          'profile': facts.profile,
          'visibleApplicationCount': applications.length,
          'usageAggregateCount': count
        })}');
  });
}
