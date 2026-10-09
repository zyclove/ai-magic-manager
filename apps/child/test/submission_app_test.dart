import 'package:child/core/session.dart';
import 'package:child/ui/child_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/identity_fixture.dart';
import 'support/submission_fixture.dart';

void main() {
  testWidgets(
      'connected child can reach the request workflow from the rules tab',
      (tester) async {
    final identity = IdentityFixture();
    await identity.activate();
    final receiver = SubmissionFixture();
    await receiver.open();
    addTearDown(identity.close);
    addTearDown(receiver.dispose);
    await tester.pumpWidget(ChildApp(
        nativeAvailable: true,
        session: ChildSession(
            identity: identity.identity,
            submissionFactory: (_) async => receiver)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('规则'));
    await tester.pumpAndSettle();
    expect(find.text('临时访问申请'), findsOneWidget);
    await tester.ensureVisible(find.text('申请临时访问'));
    await tester.tap(find.text('申请临时访问'));
    await tester.pumpAndSettle();
    expect(find.text('选择申请应用'), findsOneWidget);
    expect(find.text('阅读空间'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
