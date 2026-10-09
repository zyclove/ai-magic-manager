import 'dart:async';
import 'package:child/core/session.dart';
import 'package:child/ui/child_app.dart';
import 'package:device_identity/device_identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/identity_fixture.dart';
import 'support/submission_fixture.dart';

class _DelayedSecrets implements DeviceSecretStore {
  final delegate = FixtureSecrets();
  Completer<void>? gate;
  bool fail = false;
  @override
  Future<String?> read() async {
    await gate?.future;
    if (fail) throw StateError('Controlled private storage failure');
    return delegate.read();
  }

  @override
  Future<void> write(String value) => delegate.write(value);
}

void main() {
  for (final fail in [false, true]) {
    testWidgets(
        'in-flight identity read preserves form; failure=$fail clears it',
        (tester) async {
      final secrets = _DelayedSecrets();
      final identity = IdentityFixture(nativeSecrets: secrets);
      await identity.activate();
      final receiver = SubmissionFixture();
      await receiver.open();
      final session = ChildSession(
          identity: identity.identity,
          submissionFactory: (_) async => receiver);
      addTearDown(identity.close);
      addTearDown(receiver.dispose);
      await tester
          .pumpWidget(ChildApp(nativeAvailable: true, session: session));
      await tester.pumpAndSettle();
      Future<void> tap(String label) async {
        await tester.ensureVisible(find.text(label).last);
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await tap('规则');
      await tap('申请临时访问');
      await tap('阅读空间');
      await tester.enterText(
          find.byKey(const Key('submission-reason')), '私人理由');
      await tap('核对申请');
      secrets.gate = Completer<void>();
      await tester.tap(find.text('提交给监护人'));
      await tester.pump();
      expect(session.busy, isTrue);
      expect(receiver.mutations, 0);
      expect(find.text('确认申请内容'), findsOneWidget);
      expect(find.text('私人理由'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '提交给监护人'))
              .onPressed,
          isNull);
      secrets.fail = fail;
      secrets.gate!.complete();
      await tester.pumpAndSettle();
      expect(session.busy, isFalse);
      expect(find.byType(Dialog), findsNothing);
      if (fail) {
        expect(session.credentialReady, isFalse);
        expect(session.identityReadSucceeded, isFalse);
        expect(session.submissions.journal, isNull);
        expect(receiver.mutations, 0);
        expect(find.text('私人理由'), findsNothing);
      } else {
        expect(session.credentialReady, isTrue);
        expect(receiver.mutations, 1);
        expect(
            session.submissions.journal!.entries.single.value.reason, '私人理由');
        expect(find.text('等待监护人审批'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
