import 'package:child/ui/child_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/identity_fixture.dart';

void main() {
  testWidgets(
      'guardian confirmation appears automatically without another child tap',
      (tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await fixture.pair();
    await tester.pumpWidget(
        ChildApp(session: fixture.session(), nativeAvailable: true));
    await tester.pumpAndSettle();
    fixture.confirmed = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('设备身份已确认'), findsOneWidget);
  });
  testWidgets('scan claims the real device identity with no credential typing',
      (tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await tester.pumpWidget(ChildApp(
        session: fixture.session(),
        nativeAvailable: true,
        pairingScanner: (_) async => fixture.ticket));
    await tester.pumpAndSettle();
    await tester.tap(find.text('扫描家长端二维码'));
    await tester.pumpAndSettle();
    expect(find.text('等待监护人确认'), findsOneWidget);
    expect(find.text('1234 5678'), findsOneWidget);
    expect(fixture.calls, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('unrelated QR code never contacts enrollment API',
      (tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await tester.pumpWidget(ChildApp(
        session: fixture.session(),
        nativeAvailable: true,
        pairingScanner: (_) async => 'https://untrusted.invalid/'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('扫描家长端二维码'));
    await tester.pumpAndSettle();
    expect(fixture.calls, 0);
    expect(find.text('请扫描家长端显示的配对二维码。'), findsOneWidget);
  });
}
