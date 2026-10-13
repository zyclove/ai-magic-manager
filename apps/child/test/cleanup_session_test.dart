import 'dart:async';
import 'package:child/core/access.dart';
import 'package:child/core/session.dart';
import 'package:device_cleanup/device_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/identity_fixture.dart';
import 'support/session_idle.dart';
import 'support/submission_fixture.dart';

// Deliberately controllable cache owners and cleanup callback. These verify
// session orchestration only; actual host files are covered in executor tests.
class _Closing {
  final started = Completer<void>();
  final release = Completer<void>();
  bool fail = false, closed = false;
  Future<void> close() async {
    if (!started.isCompleted) started.complete();
    await release.future;
    if (fail) throw StateError('controlled close failure');
    closed = true;
  }
}

class _Rules implements ChildRuleReceiver {
  final _Closing closing;
  _Rules(this.closing);
  @override
  Future<ChildRules> restore() async => const ChildRules();
  @override
  Future<ChildRules> synchronize() async => const ChildRules();
  @override
  Future<void> close() => closing.close();
}

class _Access implements ChildAccessReceiver {
  final _Closing closing;
  _Access(this.closing);
  @override
  Future<ChildAccessSnapshot> restore() async => const ChildAccessSnapshot();
  @override
  Future<ChildAccessSnapshot> synchronize() => restore();
  @override
  void pause() {}
  @override
  void resume() {}
  @override
  Future<void> close() => closing.close();
}

class _Requests extends SubmissionFixture {
  final _Closing closing;
  _Requests(this.closing);
  @override
  Future<void> close() => closing.close();
}

void main() {
  late IdentityFixture fixture;
  ChildSession? session;
  setUp(() async {
    fixture = IdentityFixture();
    await fixture.activate();
  });
  tearDown(() {
    session?.dispose();
    fixture.close();
    session = null;
  });

  test('startup waits for cleanup check before opening any cache', () async {
    final checking = Completer<void>(), finish = Completer<void>();
    final closing = _Closing()..release.complete();
    var opens = 0;
    session = ChildSession(
        identity: fixture.identity,
        cleanupCheck: () async {
          checking.complete();
          await finish.future;
          return null;
        },
        ruleReceiverFactory: (_) async {
          opens++;
          return _Rules(closing);
        });
    final initializing = session!.initialize();
    await checking.future;
    expect(opens, 0);
    expect(session!.busy, isTrue);
    finish.complete();
    await initializing;
    await waitForSessionIdle(session!);
    expect(opens, 1);
  });

  test('retry awaits all cache owners and rejects overlapping user action',
      () async {
    final rules = _Closing(), access = _Closing(), requests = _Closing();
    final submission = _Requests(requests);
    await submission.open();
    addTearDown(submission.dispose);
    var checks = 0;
    session = ChildSession(
        identity: fixture.identity,
        nowMillis: () => fixture.clock,
        ruleReceiverFactory: (_) async => _Rules(rules),
        accessFactory: (_, baseline) async => _Access(access),
        submissionFactory: (_) async => submission,
        cleanupCheck: () async {
          if (++checks == 1) return null;
          expect([rules.closed, access.closed, requests.closed],
              everyElement(isTrue));
          fixture.secrets.record = null;
          return CleanupRunStage.keyRemoved;
        });
    await session!.initialize();
    await waitForSessionIdle(session!);
    final retrying = session!.retryCleanup();
    await Future.wait(
        [rules.started.future, access.started.future, requests.started.future]);
    expect(checks, 1);
    expect(await session!.retryCleanup(), isFalse);
    rules.release.complete();
    access.release.complete();
    await Future<void>.delayed(Duration.zero);
    expect(checks, 1);
    requests.release.complete();
    expect(await retrying, isTrue);
    expect(checks, 2);
    expect(session!.cleanupCompletedThisSession, isTrue);
    expect(session!.identityView, isNull);
    expect(session!.credentialReady, isFalse);
  });

  test('failed cache close permanently blocks cleanup in that session',
      () async {
    final closing = _Closing()..fail = true;
    var checks = 0, opens = 0;
    session = ChildSession(
        identity: fixture.identity,
        cleanupCheck: () async {
          checks++;
          return null;
        },
        ruleReceiverFactory: (_) async {
          opens++;
          return _Rules(closing);
        });
    await session!.initialize();
    await waitForSessionIdle(session!);
    final retrying = session!.retryCleanup();
    await closing.started.future;
    closing.release.complete();
    expect(await retrying, isFalse);
    await waitForSessionIdle(session!);
    expect(session!.cleanupErrorCode, 'CLEANUP_NOT_QUIESCENT');
    expect(checks, 1);
    expect(opens, 1);
    expect(await session!.retryCleanup(), isFalse);
    expect(checks, 1);
  });

  test('local clear failure is an explicit unsuccessful retry', () async {
    var fail = false;
    session = ChildSession(
        identity: fixture.identity,
        cleanupCheck: () async =>
            fail ? CleanupRunStage.localClearFailed : null);
    await session!.initialize();
    fail = true;
    expect(await session!.retryCleanup(), isFalse);
    expect(session!.cleanupErrorCode, 'CLEANUP_LOCAL_CLEAR_FAILED');
    expect(session!.cleanupCompletedThisSession, isFalse);
  });

  test('connection check never sends heartbeat after cleanup uncertainty',
      () async {
    var fail = false;
    session = ChildSession(
        identity: fixture.identity,
        cleanupCheck: () async {
          if (fail) throw const CleanupFailure('CLEANUP_JOURNAL_UNAVAILABLE');
          return null;
        });
    await session!.initialize();
    final calls = fixture.calls;
    fail = true;
    await session!.checkConnection();
    expect(fixture.calls, calls);
    expect(session!.cleanupErrorCode, 'CLEANUP_JOURNAL_UNAVAILABLE');
    expect(session!.cleanupCompletedThisSession, isFalse);
  });

  test('startup completion opens no cache and sends no new heartbeat',
      () async {
    var opens = 0;
    final calls = fixture.calls;
    session = ChildSession(
        identity: fixture.identity,
        cleanupCheck: () async {
          fixture.secrets.record = null;
          return CleanupRunStage.keyRemoved;
        },
        ruleReceiverFactory: (_) async {
          opens++;
          throw StateError('Cache must not open after cleanup');
        });
    await session!.initialize();
    expect(session!.cleanupCompletedThisSession, isTrue);
    expect(session!.identityView, isNull);
    expect(opens, 0);
    expect(fixture.calls, calls);
  });

  test('background retry does nothing, foreground retries prior unknown check',
      () async {
    var checks = 0;
    session = ChildSession(
        identity: fixture.identity,
        cleanupCheck: () async {
          if (++checks == 1) {
            throw const CleanupFailure('CLEANUP_NETWORK_FAILED');
          }
          return null;
        });
    await session!.initialize();
    expect(checks, 1);
    await session!.setForeground(false);
    expect(await session!.retryCleanup(), isFalse);
    expect(checks, 1);
    await session!.setForeground(true);
    expect(checks, 2);
    expect(session!.cleanupErrorCode, isNull);
  });
}
