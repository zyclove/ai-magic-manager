import 'package:child/core/session.dart';
import 'package:child/ui/child_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'access_session_test.dart' show SessionAccessReceiver;
import 'support/identity_fixture.dart';

void main() {
  testWidgets(
      'actual rules navigation exposes read-only access and sync action',
      (tester) async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final receiver = SessionAccessReceiver(fixture);
    final session = ChildSession(
        identity: fixture.identity,
        nowMillis: () => fixture.clock,
        accessFactory: (_, baseline) async => receiver);
    await tester.pumpWidget(ChildApp(session: session, nativeAvailable: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('规则'));
    await tester.pumpAndSettle();
    expect(find.text('我的规则'), findsOneWidget);
    expect(find.text('临时访问'), findsOneWidget);
    expect(find.text('单元测试应用'), findsOneWidget);
    final before = receiver.syncs;
    final action = find.widgetWithText(FilledButton, '同步临时访问');
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(receiver.syncs, before + 1);
    expect(find.text('批准'), findsNothing);
    expect(find.text('延长时间'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
