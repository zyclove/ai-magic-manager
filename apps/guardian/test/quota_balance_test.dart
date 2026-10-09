import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/ui/quota_balance.dart';

void main() {
  test('quota display retains seconds and signed ledger changes', () {
    expect(quotaDuration(0), '0 秒');
    expect(quotaDuration(60), '1 分钟');
    expect(quotaDuration(61), '1 分 1 秒');
    expect(quotaDelta(-61), '−1 分 1 秒');
    expect(quotaDelta(120), '+2 分钟');
  });
  testWidgets('zero balance and narrow screens have accessible distinct states',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: QuotaBalance(pool: {
      'limitSeconds': 600,
      'usedSeconds': 60,
      'reservedSeconds': 120,
      'availableSeconds': 420,
    }))));
    expect(find.text('已结算 1 分钟'), findsOneWidget);
    expect(find.text('待确认预留 2 分钟'), findsOneWidget);
    expect(find.text('可分配 7 分钟'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: QuotaBalance(pool: {
      'limitSeconds': 0,
      'usedSeconds': 0,
      'reservedSeconds': 0,
      'availableSeconds': 0,
    }))));
    expect(find.text('可分配 0 秒'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
