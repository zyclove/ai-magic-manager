import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/ui/usage_trend_view.dart';
import 'package:guardian/ui/design.dart';
import 'usage_trends_test.dart' show day;

void main() {
  testWidgets(
      'narrow trend renders unknown separately and exposes accessible range text',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(MaterialApp(
          theme: consoleTheme(),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: UsageTrendView(buckets: [
            day(1, null, null),
            day(2, 1501, 2501),
            day(3, 2000, 4000)
          ], timeZone: 'UTC', period: 'DAY')))));
      await tester.pumpAndSettle();
      expect(find.text('使用趋势'), findsOneWidget);
      expect(find.textContaining('无法确定增减'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('.*无观测证据.*')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('.*1 秒 – 3 秒.*')), findsWidgets);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
