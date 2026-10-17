@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/ui/managed_application_evidence_dialog.dart';
import 'package:guardian/ui/managed_agent_binding_dialog.dart';
import 'managed_enrollment_page_test.dart' as fixture;
import 'managed_agent_binding_fixtures.dart';

// The parent intentionally stays busy while its child is open. Its progress
// animation continues behind the non-opaque dialog, so wait for bounded frames.
Future<void> _settleApplicationJourney(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets(
      'real association page selects reads and explicitly checks an application',
      (tester) async {
    const application = '88888888-8888-4888-8888-888888888888';
    final binding = AgentBindingFixture()
      ..binding = AgentBindingFixture().record(state: 'VERIFIED', version: 2);
    final session = fixture.EnrollmentSession(
        bound: true,
        extra: (request) async {
          if (request.url.path.endsWith('/applications')) {
            return fixture.reply({
              'items': [
                {
                  'id': application,
                  'displayName': '页面核验合成应用',
                  'platform': 'ANDROID',
                  'packageName': 'com.example.pageevidence',
                  'profile': 'PRIMARY',
                  'signingDigests': <String>[],
                  'evidenceStatus': 'ADMIN_DECLARED',
                }
              ],
              'nextCursor': null,
            });
          }
          if (request.url.path
              .contains('/applications/$application/evidence')) {
            final refreshed = request.method == 'POST';
            final now = DateTime.now().millisecondsSinceEpoch;
            return fixture.reply({
              'bindingId': bindingId,
              'applicationId': application,
              'state': refreshed ? 'VERIFIED_IDENTITY' : 'ABSENT',
              'reasonCode': refreshed
                  ? 'MANAGED_APPLICATION_CONTROL_VERIFIED'
                  : 'MANAGED_APPLICATION_EVIDENCE_REQUIRED',
              'version': refreshed ? 1 : 0,
              'profileScope': refreshed ? 'PRIMARY' : 'UNKNOWN',
              'systemControlAvailable': refreshed,
              'reportedAt': refreshed ? now : null,
              'retrievedAt': refreshed ? now : null,
              'expiresAt': refreshed ? now + 120000 : null,
              'nextRefreshAt': refreshed ? now + 30000 : null,
              'controlOperations': refreshed
                  ? [
                      {
                        'kind': 'APP_LAUNCH',
                        'effect': 'DENY',
                        'permission': null
                      }
                    ]
                  : [],
            });
          }
          return request.url.path.contains('/agent-bindings')
              ? binding.handle(request)
              : null;
        })
      ..rows = [fixture.row(state: 'VERIFIED', version: 2)];
    await fixture.mount(tester, session);
    await tester.ensureVisible(find.text('关联儿童端'));
    await tester.tap(find.text('关联儿童端'));
    await _settleApplicationJourney(tester);
    final entry = find.byKey(const Key('managed-binding-application-evidence'));
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await _settleApplicationJourney(tester);
    expect(find.byType(ManagedApplicationEvidenceDialog), findsOneWidget);
    expect(session.requests.where((r) => r.url.path.contains('/applications/')),
        isEmpty,
        reason: 'Opening the directory cannot silently select or POST.');
    final declaration =
        find.byKey(const Key('managed-evidence-application-$application'));
    await tester.ensureVisible(declaration);
    await tester.tap(declaration);
    await _settleApplicationJourney(tester);
    final evidenceReads = session.requests.where(
        (r) => r.url.path.endsWith('/applications/$application/evidence'));
    expect(evidenceReads, hasLength(1));
    expect(evidenceReads.single.method, 'GET');
    expect(evidenceReads.single.headers['If-Match'], '"2"');
    final primary = find.byKey(const Key('managed-evidence-primary'));
    await tester.ensureVisible(primary);
    await tester.tap(primary);
    await _settleApplicationJourney(tester);
    final checks = session.requests.where((r) =>
        r.url.path.endsWith('/applications/$application/evidence/refresh'));
    expect(checks, hasLength(1));
    expect(checks.single.method, 'POST');
    expect(checks.single.headers['If-Match'], '"2"');
    expect(checks.single.body, isEmpty);
    await tester.ensureVisible(find.byKey(const Key('managed-evidence-close')));
    await tester.tap(find.byKey(const Key('managed-evidence-close')));
    await _settleApplicationJourney(tester);
    await _settleApplicationJourney(tester);
    expect(find.byType(ManagedApplicationEvidenceDialog), findsNothing);
    expect(find.byType(ManagedAgentBindingDialog), findsOneWidget);
    session.invalidate();
    await _settleApplicationJourney(tester);
    expect(find.byType(ManagedAgentBindingDialog), findsNothing);
    expect(checks, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('verified enrollment exposes the child binding workflow',
      (tester) async {
    final session = fixture.EnrollmentSession(bound: true)
      ..rows = [fixture.row(state: 'VERIFIED', version: 2)];
    await fixture.mount(tester, session);
    expect(find.text('关联儿童端'), findsOneWidget);
  });
  testWidgets(
      'real page opens scoped selection and closes it on workspace invalidation',
      (tester) async {
    final binding = AgentBindingFixture();
    final session = fixture.EnrollmentSession(
        bound: true,
        extra: (r) async =>
            r.url.path.contains('/agent-bindings') ? binding.handle(r) : null)
      ..rows = [fixture.row(state: 'VERIFIED', version: 2)];
    await fixture.mount(tester, session);
    await tester.ensureVisible(find.text('关联儿童端'));
    await tester.tap(find.text('关联儿童端'));
    await fixture.settle(tester);
    expect(find.text('学习平板'), findsOneWidget);
    session.invalidate();
    await fixture.settle(tester);
    expect(find.byType(ManagedAgentBindingDialog), findsNothing);
    expect(binding.createCount, 0);
  });
  testWidgets('auditor can inspect current association but cannot mutate',
      (tester) async {
    final binding = AgentBindingFixture()
      ..binding = AgentBindingFixture().record(state: 'VERIFIED', version: 2);
    final session = fixture.EnrollmentSession(
        bound: true,
        actorRole: 'AUDITOR',
        extra: (r) async =>
            r.url.path.contains('/agent-bindings') ? binding.handle(r) : null)
      ..rows = [fixture.row(state: 'VERIFIED', version: 2)];
    await fixture.mount(tester, session);
    await tester.ensureVisible(find.text('查看儿童端关联'));
    await tester.tap(find.text('查看儿童端关联'));
    await fixture.settle(tester);
    expect(find.text('儿童端身份已核验'), findsOneWidget);
    expect(find.text('撤销此关联'), findsNothing);
    expect(find.text('开始关联'), findsNothing);
  });
}
