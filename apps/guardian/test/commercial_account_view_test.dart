import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/commercial_entitlements.dart';
import 'package:guardian/ui/commercial_account_view.dart';
import 'package:guardian/ui/design.dart';

const tenant = '11111111-1111-1111-1111-111111111111';

CommercialEntitlements rights({bool empty = false}) =>
    CommercialEntitlements.parse({
      'tenantId': tenant,
      'version': empty ? 0 : 3,
      'evaluatedAt': 1791619200000,
      'activeSourceCount': empty ? 0 : 2,
      'baseDeviceCapacity': empty ? 0 : 5,
      'addOnDeviceCapacity': empty ? 0 : 2,
      'paidDeviceCapacity': empty ? 0 : 7,
      'features':
          empty ? <String>[] : ['ADVANCED_SCHEDULES', 'MANAGED_ANDROID'],
      'technicalCapabilityIndependent': true
    }, tenant);

void main() {
  Future<void> show(WidgetTester tester, double width,
      {bool empty = false}) async {
    tester.view.physicalSize = Size(width, 840);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: CommercialAccountView(rights: rights(empty: empty))))));
    await tester.pumpAndSettle();
  }

  testWidgets('desktop explains paid rights and separate technical capability',
      (tester) async {
    await show(tester, 1200);
    expect(find.text('当前付费设备名额'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('受管 Android 功能权益'), findsOneWidget);
    expect(find.textContaining('设备可执行能力分别核验'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone renders zero-rights state without false purchase action',
      (tester) async {
    await show(tester, 390, empty: true);
    expect(find.text('暂无经过核验的付费来源。基础安全功能和设备退出不因此关闭。'), findsOneWidget);
    expect(find.text('暂无已核验的付费功能权益。'), findsOneWidget);
    expect(find.textContaining('立即购买'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
