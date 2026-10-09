import 'dart:async';
import 'package:child/core/session.dart';
import 'package:child/core/submissions.dart';
import 'package:device_access/device_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/identity_fixture.dart';
import 'support/submission_fixture.dart';

Future<void> idle(ChildSession session) async {
  for (var i = 0; i < 80 && session.busy; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(session.busy, isFalse);
}

void main() {
  late IdentityFixture identity;
  late SubmissionFixture receiver;
  late ChildSession session;
  setUp(() async {
    identity = IdentityFixture();
    await identity.activate();
    receiver = SubmissionFixture();
    await receiver.open();
    session = ChildSession(
        identity: identity.identity, submissionFactory: (_) async => receiver);
  });
  tearDown(() async {
    session.dispose();
    identity.close();
    await receiver.dispose();
  });
  test('initialize reads request facts without automatically sending mutations',
      () async {
    await session.initialize();
    await idle(session);
    expect(session.submissions.contextReady, isTrue);
    expect(session.submissions.options.single.applications.single.displayName,
        '阅读空间');
    expect((await receiver.journal.inspect()).pending, isNull);
    expect(receiver.mutations, 0);
    expect(session.systemEnforced, isFalse);
  });
  test(
      'unknown submission stays visible and explicit retry completes the original',
      () async {
    await session.initialize();
    await idle(session);
    receiver.loseResponse = true;
    expect(
        await session.createSubmission(SubmissionFixture.input(),
            applicationName: '阅读空间'),
        isFalse);
    final original = session.submissions.journal!.pending!;
    expect(original.phase, SubmissionOperationPhase.unknown);
    expect(original.key, isNotEmpty);
    expect(session.submissionErrorCode, 'NETWORK_TIMEOUT');
    expect(session.submissionCorrelationId, 'fixture-correlation');
    expect(session.errorCode, isNull);
    expect(await session.discardSubmission(), isFalse);
    expect(session.submissions.journal!.pending!.key, original.key);
    receiver.loseResponse = false;
    expect(await session.retrySubmission(), isTrue);
    expect(session.submissions.journal!.pending, isNull);
    expect(session.submissions.journal!.entries.single.value.id,
        SubmissionFixture.request);
  });
  test(
      'background hides facts and a late refresh cannot republish private data',
      () async {
    await session.initialize();
    await idle(session);
    receiver.refreshGate = Completer<void>();
    final running = session.refreshSubmissions();
    await Future<void>.delayed(Duration.zero);
    await session.setForeground(false);
    expect(session.submissions.journal, isNull);
    expect(session.foreground, isFalse);
    receiver.refreshGate!.complete();
    await running;
    expect(session.submissions.journal, isNull);
    await session.setForeground(true);
    await idle(session);
    expect(session.submissions.contextReady, isTrue);
  });
  test('authorization failure does not resurrect cached request facts',
      () async {
    await session.initialize();
    await idle(session);
    await session.submissionDetail(SubmissionFixture.request);
    receiver.failure =
        const AccessTransportFailure('DEVICE_UNAUTHENTICATED', status: 401);
    expect(await session.refreshSubmissions(), isFalse);
    expect(session.submissions.journal, isNull);
    expect(session.submissionErrorCode, 'DEVICE_UNAUTHENTICATED');
    identity.rejectAuthentication = true;
    await session.checkConnection();
    expect(receiver.closed, isTrue);
    expect(session.submissions.journal, isNull);
  });
  test('receiver created after background transition is closed before reading',
      () async {
    session.dispose();
    final created = Completer<ChildSubmissions>();
    final creating = Completer<void>();
    session = ChildSession(
        identity: identity.identity,
        submissionFactory: (_) {
          creating.complete();
          return created.future;
        });
    final initializing = session.initialize();
    await creating.future;
    await session.setForeground(false);
    created.complete(receiver);
    await initializing;
    expect(receiver.closed, isTrue);
    expect(receiver.restores, 0);
    expect(session.submissions.journal, isNull);
  });
  test(
      'empty option pages can continue and cancellation uses the selected fact',
      () async {
    receiver.options = [];
    receiver.optionsCursor = SubmissionFixture.policy;
    receiver.requestsCursor = SubmissionFixture.request;
    await session.initialize();
    await idle(session);
    expect(session.submissions.options, isEmpty);
    await session.moreSubmissionOptions();
    expect(session.submissions.options, hasLength(1));
    await session.moreSubmissions();
    final value = session.submissions.journal!.entries.single.value;
    expect(
        await session.cancelSubmission(value, applicationName: '阅读空间'), isTrue);
    expect(
        session.submissions.journal!.entries.single.value.state, 'CANCELLED');
    expect(session.submissions.journal!.entries.single.value.version, 1);
  });
}
